import Darwin
import Foundation

enum URLSafetyError: Error, CustomStringConvertible {
    case invalidURL
    case blockedHost(String)
    case resolutionFailed(String)
    case tooManyRedirects

    var description: String {
        switch self {
        case .invalidURL: "Invalid HTTP or HTTPS URL"
        case .blockedHost(let host): "Blocked non-public network destination: \(host)"
        case .resolutionFailed(let host): "Could not resolve destination: \(host)"
        case .tooManyRedirects: "Too many HTTP redirects"
        }
    }
}

enum URLSafety {
    static func validate(_ url: URL, allowPrivateNetworks: Bool) async throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw URLSafetyError.invalidURL }
        guard !url.absoluteString.contains("@") else { throw URLSafetyError.invalidURL }
        if allowPrivateNetworks { return }

        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") {
            throw URLSafetyError.blockedHost(host)
        }
        let addresses = await resolve(host)
        guard !addresses.isEmpty else { throw URLSafetyError.resolutionFailed(host) }
        guard addresses.allSatisfy(isPublic) else { throw URLSafetyError.blockedHost(host) }
    }

    static func isPublic(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let a = bytes[0], b = bytes[1], c = bytes[2]
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && ((b == 0 && (c == 0 || c == 2)) || b == 168 || (b == 88 && c == 99)) { return false }
            if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            return true
        }
        if bytes.count == 16 {
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
            if bytes[0] & 0xFE == 0xFC { return false } // unique-local fc00::/7
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false } // link-local fe80::/10
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0xC0 { return false } // site-local fec0::/10
            if bytes[0] == 0xFF { return false } // multicast
            if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false } // documentation
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return isPublic(Array(bytes[12...15]))
            }
            if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
            return true
        }
        return false
    }

    private static func resolve(_ host: String) async -> [[UInt8]] {
        await Task.detached {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                ai_addr: nil, ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [[UInt8]] = []
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let info = current?.pointee {
                if info.ai_family == AF_INET, let address = info.ai_addr {
                    let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    addresses.append(withUnsafeBytes(of: value) { Array($0) })
                } else if info.ai_family == AF_INET6, let address = info.ai_addr {
                    let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    addresses.append(withUnsafeBytes(of: value) { Array($0.prefix(16)) })
                }
                current = info.ai_next
            }
            return addresses
        }.value
    }
}
