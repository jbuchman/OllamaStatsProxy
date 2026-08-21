import Foundation
import GRDB

actor StatsStore {
    private let database: DatabasePool
    private let sessionStart = Date()
    private var active: [Int64: RequestRecord] = [:]
    private var recentTokenTimes: [Int64: [Date]] = [:]
    private var resourceSamplers: [Int64: Task<Void, Never>] = [:]
    private var resourceSamples: [Int64: ResourceAccumulator] = [:]

    private struct ResourceAccumulator: Sendable {
        var count = 0
        var cpuTotal = 0.0
        var cpuCount = 0
        var gpuTotal = 0.0
        var gpuCount = 0
        var memoryTotal: Int64 = 0
        var memoryCount = 0
    }

    init(path: String) throws {
        database = try DatabasePool(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRequests") { db in
            try db.create(table: RequestRecord.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("model", .text).notNull()
                table.column("endpoint", .text).notNull()
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("endedAt", .datetime)
                table.column("promptTokens", .integer).notNull().defaults(to: 0)
                table.column("outputTokens", .integer).notNull().defaults(to: 0)
                table.column("firstTokenAt", .datetime)
                table.column("totalDurationNanoseconds", .integer)
                table.column("loadDurationNanoseconds", .integer)
                table.column("promptEvalDurationNanoseconds", .integer)
                table.column("evalDurationNanoseconds", .integer)
                table.column("temperature", .double)
                table.column("contextLength", .integer)
                table.column("thinkingEnabled", .boolean)
                table.column("benchmarkLabel", .text)
                table.column("resourceSampleCount", .integer).notNull().defaults(to: 0)
                table.column("averageCPUPercent", .double)
                table.column("averageGPUPercent", .double)
                table.column("averageMemoryUsedBytes", .integer)
                table.column("error", .text)
            }
        }
        migrator.registerMigration("addBenchmarkMetrics") { db in
            let columns = try db.columns(in: RequestRecord.databaseTableName).map(\.name)
            func add(_ name: String, _ type: Database.ColumnType) throws {
                guard !columns.contains(name) else { return }
                try db.alter(table: RequestRecord.databaseTableName) { $0.add(column: name, type) }
            }
            try add("firstTokenAt", .datetime)
            try add("totalDurationNanoseconds", .integer)
            try add("loadDurationNanoseconds", .integer)
            try add("promptEvalDurationNanoseconds", .integer)
            try add("evalDurationNanoseconds", .integer)
            try add("temperature", .double)
            try add("contextLength", .integer)
            try add("thinkingEnabled", .boolean)
            try add("benchmarkLabel", .text)
        }
        migrator.registerMigration("createWebToolCalls") { db in
            try db.create(table: WebToolRecord.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("requestID", .integer)
                    .references(RequestRecord.databaseTableName, onDelete: .setNull)
                    .indexed()
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("endedAt", .datetime).notNull()
                table.column("tool", .text).notNull()
                table.column("source", .text).notNull()
                table.column("resource", .text).notNull()
                table.column("host", .text)
                table.column("resultCount", .integer)
                table.column("responseBytes", .integer)
                table.column("error", .text)
            }
        }
        migrator.registerMigration("addResourceMetrics") { db in
            let columns = try db.columns(in: RequestRecord.databaseTableName).map(\.name)
            if !columns.contains("resourceSampleCount") {
                try db.alter(table: RequestRecord.databaseTableName) {
                    $0.add(column: "resourceSampleCount", .integer).notNull().defaults(to: 0)
                }
            }
            if !columns.contains("averageCPUPercent") {
                try db.alter(table: RequestRecord.databaseTableName) { $0.add(column: "averageCPUPercent", .double) }
            }
            if !columns.contains("averageMemoryUsedBytes") {
                try db.alter(table: RequestRecord.databaseTableName) { $0.add(column: "averageMemoryUsedBytes", .integer) }
            }
        }
        migrator.registerMigration("addGPUMetrics") { db in
            let columns = try db.columns(in: RequestRecord.databaseTableName).map(\.name)
            if !columns.contains("averageGPUPercent") {
                try db.alter(table: RequestRecord.databaseTableName) { $0.add(column: "averageGPUPercent", .double) }
            }
        }
        try migrator.migrate(database)
        try database.write { db in
            try db.execute(
                sql: "UPDATE requests SET endedAt = ?, error = COALESCE(error, 'proxy stopped before request completed') WHERE endedAt IS NULL",
                arguments: [Date()]
            )
        }
    }

    func begin(metadata: RequestMetadata) throws -> Int64 {
        let record = RequestRecord(
            id: nil, model: metadata.model, endpoint: metadata.endpoint, startedAt: Date(), endedAt: nil,
            promptTokens: 0, outputTokens: 0, firstTokenAt: nil,
            totalDurationNanoseconds: nil, loadDurationNanoseconds: nil,
            promptEvalDurationNanoseconds: nil, evalDurationNanoseconds: nil,
            temperature: metadata.temperature, contextLength: metadata.contextLength,
            thinkingEnabled: metadata.thinkingEnabled, benchmarkLabel: metadata.benchmarkLabel,
            resourceSampleCount: 0, averageCPUPercent: nil, averageGPUPercent: nil,
            averageMemoryUsedBytes: nil,
            error: nil
        )
        let id = try database.write { db -> Int64 in
            try record.insert(db)
            return db.lastInsertedRowID
        }
        var activeRecord = record
        activeRecord.id = id
        active[id] = activeRecord
        recentTokenTimes[id] = []
        resourceSamples[id] = ResourceAccumulator()
        resourceSamplers[id] = Task { [weak self] in
            while !Task.isCancelled {
                let usage = await SystemCollector.collectResourceUsage()
                guard !Task.isCancelled else { break }
                await self?.recordResourceSample(requestID: id, usage: usage)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return id
    }

    private func recordResourceSample(requestID: Int64, usage: SystemCollector.ResourceUsage) {
        guard active[requestID] != nil, var samples = resourceSamples[requestID] else { return }
        samples.count += 1
        if let cpu = usage.cpuPercent {
            samples.cpuTotal += cpu
            samples.cpuCount += 1
        }
        if let gpu = usage.gpuPercent {
            samples.gpuTotal += gpu
            samples.gpuCount += 1
        }
        if let memory = usage.memoryUsedBytes {
            samples.memoryTotal += memory
            samples.memoryCount += 1
        }
        resourceSamples[requestID] = samples
    }

    func streamedToken(requestID: Int64) {
        guard var record = active[requestID] else { return }
        if record.firstTokenAt == nil { record.firstTokenAt = Date() }
        record.outputTokens += 1
        active[requestID] = record
        let cutoff = Date().addingTimeInterval(-2)
        var times = recentTokenTimes[requestID, default: []].filter { $0 >= cutoff }
        times.append(Date())
        recentTokenTimes[requestID] = times
    }

    func reconcile(requestID: Int64, metrics: FinalMetrics) {
        guard var record = active[requestID] else { return }
        if let output = metrics.outputTokens { record.outputTokens = output }
        if let prompt = metrics.promptTokens { record.promptTokens = prompt }
        if record.firstTokenAt == nil, (metrics.outputTokens ?? 0) > 0 { record.firstTokenAt = Date() }
        record.totalDurationNanoseconds = metrics.totalDurationNanoseconds
        record.loadDurationNanoseconds = metrics.loadDurationNanoseconds
        record.promptEvalDurationNanoseconds = metrics.promptEvalDurationNanoseconds
        record.evalDurationNanoseconds = metrics.evalDurationNanoseconds
        active[requestID] = record
    }

    func finish(requestID: Int64, error: String? = nil) throws {
        guard var record = active.removeValue(forKey: requestID) else { return }
        resourceSamplers.removeValue(forKey: requestID)?.cancel()
        recentTokenTimes.removeValue(forKey: requestID)
        if let samples = resourceSamples.removeValue(forKey: requestID) {
            record.resourceSampleCount = samples.count
            if samples.cpuCount > 0 { record.averageCPUPercent = samples.cpuTotal / Double(samples.cpuCount) }
            if samples.gpuCount > 0 { record.averageGPUPercent = samples.gpuTotal / Double(samples.gpuCount) }
            if samples.memoryCount > 0 { record.averageMemoryUsedBytes = samples.memoryTotal / Int64(samples.memoryCount) }
        }
        record.endedAt = Date()
        record.error = error
        try database.write { db in try record.update(db) }
    }

    func snapshot(limit: Int = 20) throws -> (TokenSummary, [RequestSnapshot], Double) {
        let completed: [RequestRecord] = try database.read { db in
            try RequestRecord.order(Column("id").desc).limit(limit).fetchAll(db)
        }
        let totals: Row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(outputTokens), 0) AS output, COALESCE(SUM(promptTokens), 0) AS prompt, COUNT(*) AS count FROM requests")!
        }
        let now = Date()
        let activeRecords = active.values.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        let liveTPS = activeRecords.reduce(0.0) { partial, record in
            let count = recentTokenTimes[record.id ?? -1, default: []].filter { now.timeIntervalSince($0) <= 2 }.count
            return partial + Double(count) / 2.0
        }
        let merged = (activeRecords + completed.filter { !active.keys.contains($0.id ?? -1) })
            .prefix(limit).map { requestSnapshot($0, now: now) }
        let totalOutput: Int = totals["output"]
        let totalPrompt: Int = totals["prompt"]
        let totalCount: Int = totals["count"]
        let summary = TokenSummary(
            outputTokens: totalOutput + activeRecords.reduce(0) { $0 + $1.outputTokens },
            promptTokens: totalPrompt + activeRecords.reduce(0) { $0 + $1.promptTokens },
            requests: totalCount,
            liveTokensPerSecond: liveTPS
        )
        return (summary, Array(merged), now.timeIntervalSince(sessionStart))
    }

    func requestPage(
        page requestedPage: Int, pageSize requestedPageSize: Int,
        query search: String? = nil, state: String? = nil
    ) throws -> PaginatedResponse<RequestSnapshot> {
        let pageSize = min(max(requestedPageSize, 1), 100)
        var request = RequestRecord.all()
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            let pattern = "%\(search)%"
            request = request.filter(
                Column("model").like(pattern) || Column("endpoint").like(pattern)
                    || Column("benchmarkLabel").like(pattern)
            )
        }
        switch state {
        case "active": request = request.filter(sql: "endedAt IS NULL")
        case "done": request = request.filter(sql: "endedAt IS NOT NULL AND error IS NULL")
        case "cancelled": request = request.filter(Column("error") == ActiveRequestRegistry.cancellationReason)
        case "error": request = request.filter(sql: "error IS NOT NULL AND error <> ?", arguments: [ActiveRequestRegistry.cancellationReason])
        default: break
        }
        let total = try database.read { db in try request.fetchCount(db) }
        let totalPages = max(1, (total + pageSize - 1) / pageSize)
        let page = min(max(requestedPage, 1), totalPages)
        let records = try database.read { db in
            try request.order(Column("id").desc)
                .limit(pageSize, offset: (page - 1) * pageSize).fetchAll(db)
        }
        let now = Date()
        return PaginatedResponse(
            items: records.map { record in
                requestSnapshot(active[record.id ?? -1] ?? record, now: now)
            },
            page: page, pageSize: pageSize, totalItems: total, totalPages: totalPages
        )
    }

    func requestDetail(id: Int64) throws -> RequestDetail? {
        guard let stored = try database.read({ db in try RequestRecord.fetchOne(db, key: id) }) else { return nil }
        let record = active[id] ?? stored
        let tools = try database.read { db in
            try WebToolRecord.filter(Column("requestID") == id).order(Column("startedAt").asc).fetchAll(db)
        }
        return RequestDetail(
            request: requestSnapshot(record, now: Date()),
            webTools: tools.map(webToolActivity)
        )
    }

    private func requestSnapshot(_ record: RequestRecord, now: Date) -> RequestSnapshot {
        let liveCount = recentTokenTimes[record.id ?? -1, default: []]
            .filter { now.timeIntervalSince($0) <= 2 }.count
        let state: String
        if record.error == ActiveRequestRegistry.cancellationReason { state = "cancelled" }
        else if record.error != nil { state = "error" }
        else if record.endedAt != nil { state = "done" }
        else if record.outputTokens == 0 && record.elapsedSeconds > 2 { state = "thinking/loading" }
        else { state = "generating" }
        return RequestSnapshot(
            id: record.id!, model: record.model, endpoint: record.endpoint,
            startedAt: record.startedAt, endedAt: record.endedAt,
            promptTokens: record.promptTokens, outputTokens: record.outputTokens,
            elapsedSeconds: record.elapsedSeconds,
            tokensPerSecond: record.endedAt == nil ? Double(liveCount) / 2.0 : record.averageTokensPerSecond,
            timeToFirstTokenSeconds: record.timeToFirstTokenSeconds,
            promptTokensPerSecond: record.promptTokensPerSecond,
            totalDurationSeconds: record.totalDurationNanoseconds.map { Double($0) / 1_000_000_000 },
            loadDurationSeconds: record.loadDurationNanoseconds.map { Double($0) / 1_000_000_000 },
            temperature: record.temperature, contextLength: record.contextLength,
            thinkingEnabled: record.thinkingEnabled, benchmarkLabel: record.benchmarkLabel,
            resourceSampleCount: record.resourceSampleCount,
            averageCPUPercent: record.averageCPUPercent,
            averageGPUPercent: record.averageGPUPercent,
            averageMemoryUsedBytes: record.averageMemoryUsedBytes,
            state: state, error: record.error
        )
    }

    func benchmarkSummaries() throws -> [BenchmarkSummary] {
        try database.read { db in
            var summaries = try BenchmarkSummary.fetchAll(db, sql: """
                SELECT model, COUNT(*) AS runs,
                  AVG(CASE WHEN evalDurationNanoseconds > 0 THEN outputTokens * 1000000000.0 / evalDurationNanoseconds ELSE outputTokens / MAX((julianday(endedAt)-julianday(startedAt))*86400.0, 0.001) END) AS averageOutputTokensPerSecond,
                  AVG(CASE WHEN promptEvalDurationNanoseconds > 0 THEN promptTokens * 1000000000.0 / promptEvalDurationNanoseconds END) AS averagePromptTokensPerSecond,
                  AVG(CASE WHEN firstTokenAt IS NOT NULL THEN (julianday(firstTokenAt)-julianday(startedAt))*86400.0 END) AS averageTimeToFirstTokenSeconds,
                  AVG(COALESCE(totalDurationNanoseconds / 1000000000.0, (julianday(endedAt)-julianday(startedAt))*86400.0)) AS averageTotalDurationSeconds,
                  AVG(averageCPUPercent) AS averageCPUPercent,
                  AVG(averageGPUPercent) AS averageGPUPercent,
                  AVG(averageMemoryUsedBytes) AS averageMemoryUsedBytes,
                  NULL AS outputTokensPerSecondDeltaPercent,
                  NULL AS timeToFirstTokenDeltaPercent
                FROM requests WHERE endedAt IS NOT NULL AND error IS NULL GROUP BY model ORDER BY averageOutputTokensPerSecond DESC
                """)
            for index in summaries.indices {
                let recent = try RequestRecord
                    .filter(Column("model") == summaries[index].model)
                    .filter(sql: "endedAt IS NOT NULL AND error IS NULL")
                    .order(Column("id").desc).limit(2).fetchAll(db)
                guard recent.count == 2 else { continue }
                let latestTPS = recent[0].averageTokensPerSecond
                let previousTPS = recent[1].averageTokensPerSecond
                if previousTPS > 0 {
                    summaries[index].outputTokensPerSecondDeltaPercent = (latestTPS - previousTPS) / previousTPS * 100
                }
                if let latestTTFT = recent[0].timeToFirstTokenSeconds,
                   let previousTTFT = recent[1].timeToFirstTokenSeconds, previousTTFT > 0 {
                    summaries[index].timeToFirstTokenDeltaPercent = (latestTTFT - previousTTFT) / previousTTFT * 100
                }
            }
            return summaries
        }
    }

    func allRequests() throws -> [RequestRecord] {
        try database.read { db in try RequestRecord.order(Column("id").asc).fetchAll(db) }
    }

    func recordWebTool(
        requestID: Int64?, startedAt: Date, tool: String, source: String,
        resource: String, resultCount: Int?, responseBytes: Int?, error: String?
    ) throws -> WebToolRecord {
        var record = WebToolRecord(
            id: nil, requestID: requestID, startedAt: startedAt, endedAt: Date(),
            tool: tool, source: source, resource: resource,
            host: tool == "fetch" ? URL(string: resource)?.host : nil,
            resultCount: resultCount, responseBytes: responseBytes, error: error
        )
        record.id = try database.write { db -> Int64 in
            try record.insert(db)
            return db.lastInsertedRowID
        }
        return record
    }

    func allWebToolCalls() throws -> [WebToolRecord] {
        try database.read { db in try WebToolRecord.order(Column("id").asc).fetchAll(db) }
    }

    func webToolPage(
        page requestedPage: Int, pageSize requestedPageSize: Int,
        query search: String? = nil, state: String? = nil
    ) throws -> PaginatedResponse<WebToolActivity> {
        let pageSize = min(max(requestedPageSize, 1), 100)
        return try database.read { db in
            var request = WebToolRecord.all()
            if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                let pattern = "%\(search)%"
                request = request.filter(
                    Column("resource").like(pattern) || Column("host").like(pattern)
                        || Column("tool").like(pattern) || Column("source").like(pattern)
                )
            }
            switch state {
            case "done": request = request.filter(Column("error") == nil)
            case "error": request = request.filter(Column("error") != nil)
            default: break
            }
            let total = try request.fetchCount(db)
            let totalPages = max(1, (total + pageSize - 1) / pageSize)
            let page = min(max(requestedPage, 1), totalPages)
            let records = try request.order(Column("id").desc)
                .limit(pageSize, offset: (page - 1) * pageSize).fetchAll(db)
            return PaginatedResponse(
                items: records.map(webToolActivity), page: page, pageSize: pageSize,
                totalItems: total, totalPages: totalPages
            )
        }
    }

    func webToolSummary(limit: Int) throws -> WebToolSummary {
        try database.read { db in
            let records = try WebToolRecord.order(Column("id").desc).limit(limit).fetchAll(db)
            let totals = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                  COALESCE(SUM(CASE WHEN error IS NULL THEN 1 ELSE 0 END), 0) AS successful,
                  COALESCE(SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END), 0) AS failed,
                  COALESCE(SUM(CASE WHEN tool = 'search' THEN 1 ELSE 0 END), 0) AS searches,
                  COALESCE(SUM(CASE WHEN tool = 'fetch' THEN 1 ELSE 0 END), 0) AS fetches,
                  COALESCE(SUM(responseBytes), 0) AS bytes
                FROM webToolCalls
                """)!
            return WebToolSummary(
                totalRequests: totals["total"], successfulRequests: totals["successful"],
                failedRequests: totals["failed"], searchRequests: totals["searches"],
                fetchRequests: totals["fetches"], responseBytes: totals["bytes"],
                recent: records.map(webToolActivity)
            )
        }
    }

    private func webToolActivity(_ record: WebToolRecord) -> WebToolActivity {
        WebToolActivity(
            id: record.id!, requestID: record.requestID, startedAt: record.startedAt,
            tool: record.tool, source: record.source, resource: record.resource, host: record.host,
            durationSeconds: record.durationSeconds, resultCount: record.resultCount,
            responseBytes: record.responseBytes, state: record.error == nil ? "done" : "error",
            error: record.error
        )
    }

    func purge(olderThan cutoff: Date) throws -> Int {
        try database.write { db in
            _ = try WebToolRecord.filter(Column("startedAt") < cutoff).deleteAll(db)
            return try RequestRecord.filter(Column("startedAt") < cutoff).deleteAll(db)
        }
    }
}
