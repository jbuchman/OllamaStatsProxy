import Foundation

enum SystemCollector {
    struct ResourceUsage: Sendable {
        var cpuPercent: Double?
        var gpuPercent: Double?
        var memoryUsedBytes: Int64?
    }

    static func collectResourceUsage() async -> ResourceUsage {
        async let memoryOutput = run("/usr/bin/vm_stat", [])
        async let cpuOutput = run("/usr/bin/top", ["-l", "1", "-n", "0"])
        async let gpuOutput = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator"])
        let (memory, cpu, gpu) = await (memoryOutput, cpuOutput, gpuOutput)
        return ResourceUsage(
            cpuPercent: parseCPU(cpu),
            gpuPercent: parseGPU(gpu).deviceUtilizationPercent.map(Double.init),
            memoryUsedBytes: parseMemory(memory).used
        )
    }

    static func collect() async -> (SystemStats, GPUStats) {
        async let processOutput = run("/bin/ps", ["-axo", "pid=,pcpu=,thcount=,rss=,command="])
        async let memoryOutput = run("/usr/bin/vm_stat", [])
        async let gpuOutput = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator"])
        async let cpuOutput = run("/usr/bin/top", ["-l", "1", "-n", "0"])

        let processes = parseProcesses(await processOutput)
        let memory = parseMemory(await memoryOutput)
        let cpu = parseCPU(await cpuOutput)
        let loads = getloadavgValues()
        let system = SystemStats(
            cpuPercent: cpu,
            coreCount: ProcessInfo.processInfo.processorCount,
            loadAverage: loads,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            ollamaProcesses: processes
        )
        return (system, parseGPU(await gpuOutput))
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> String {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Drain stdout while the child is running. Waiting first can deadlock
                // when commands such as ioreg fill the pipe's finite buffer.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            } catch { return "" }
        }.value
    }

    private static func parseProcesses(_ output: String) -> [ProcessStats] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard parts.count == 5, parts[4].localizedCaseInsensitiveContains("ollama"),
                  let pid = Int(parts[0]), let cpu = Double(parts[1]),
                  let threads = Int(parts[2]), let rssKB = Int64(parts[3]) else { return nil }
            let command = String(parts[4])
            let kind = command.contains("llama-server") || command.contains("runner") ? "runner" : command.contains("serve") ? "server" : "app"
            return ProcessStats(pid: pid, kind: kind, cpuPercent: cpu, threads: threads, residentBytes: rssKB * 1024)
        }.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private static func parseCPU(_ output: String) -> Double? {
        guard let range = output.range(of: #"CPU usage:.*?([0-9.]+)% idle"#, options: .regularExpression),
              let idleRange = output[range].range(of: #"[0-9.]+(?=% idle)"#, options: .regularExpression),
              let idle = Double(output[idleRange]) else { return nil }
        return 100 - idle
    }

    private static func parseMemory(_ output: String) -> (used: Int64?, total: Int64?) {
        guard let pageMatch = output.firstMatch(#"page size of ([0-9]+) bytes"#), let pageSize = Int64(pageMatch) else { return (nil, nil) }
        func pages(_ label: String) -> Int64 { Int64(output.firstMatch("\(NSRegularExpression.escapedPattern(for: label)): +([0-9]+)") ?? "0") ?? 0 }
        let free = pages("Pages free") + pages("Pages speculative")
        let active = pages("Pages active") + pages("Pages inactive") + pages("Pages wired down") + pages("Pages occupied by compressor")
        return (active * pageSize, (active + free) * pageSize)
    }

    private static func parseGPU(_ output: String) -> GPUStats {
        func number(_ key: String) -> Int64? { output.firstMatch("\"\(NSRegularExpression.escapedPattern(for: key))\"=([0-9]+)").flatMap(Int64.init) }
        return GPUStats(
            deviceUtilizationPercent: number("Device Utilization %").map(Int.init),
            rendererUtilizationPercent: number("Renderer Utilization %").map(Int.init),
            tilerUtilizationPercent: number("Tiler Utilization %").map(Int.init),
            memoryInUseBytes: number("In use system memory"),
            allocatedSystemMemoryBytes: number("Alloc system memory")
        )
    }

    private static func getloadavgValues() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, 3)
        return count > 0 ? Array(values.prefix(Int(count))) : []
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
