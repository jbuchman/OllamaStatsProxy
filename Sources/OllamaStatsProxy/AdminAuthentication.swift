import CryptoKit
import Foundation
import HTTPTypes

enum PasswordHasher {
    static let iterations = 600_000

    static func hash(_ password: String) -> String {
        let salt = randomData(count: 16)
        let derived = derive(password: password, salt: salt, iterations: iterations)
        return "pbkdf2-sha256$\(iterations)$\(salt.base64EncodedString())$\(derived.base64EncodedString())"
    }

    static func verify(_ password: String, encoded: String) -> Bool {
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "pbkdf2-sha256",
              let iterations = Int(parts[1]), iterations >= 100_000,
              let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let actual = derive(password: password, salt: salt, iterations: iterations)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func randomToken() -> String {
        randomData(count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func derive(password: String, salt: Data, iterations: Int) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var value = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var result = value
        if iterations > 1 {
            for _ in 2...iterations {
                value = Data(HMAC<SHA256>.authenticationCode(for: value, using: key))
                for index in result.indices { result[index] ^= value[index] }
            }
        }
        return result
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

actor AdminAuthentication {
    static let cookieName = "ollama_admin_session"
    private let configuration: ConfigurationFile
    private var sessions: [String: Date] = [:]
    private var failedLogins: [Date] = []
    private let lifetime: TimeInterval = 12 * 60 * 60

    init(configuration: ConfigurationFile) { self.configuration = configuration }

    func passwordConfigured() async -> Bool {
        !(await configuration.value().adminPasswordHash?.isEmpty ?? true)
    }

    func login(password: String) async -> String? {
        let cutoff = Date().addingTimeInterval(-60)
        failedLogins.removeAll { $0 < cutoff }
        guard failedLogins.count < 5 else { return nil }
        guard let encoded = await configuration.value().adminPasswordHash,
              PasswordHasher.verify(password, encoded: encoded) else {
            failedLogins.append(Date())
            return nil
        }
        failedLogins.removeAll()
        let token = PasswordHasher.randomToken()
        sessions[token] = Date().addingTimeInterval(lifetime)
        return token
    }

    func isAuthenticated(headers: HTTPFields) async -> Bool {
        guard await passwordConfigured() else { return true }
        purgeExpired()
        guard let token = Self.cookie(in: headers) else { return false }
        return sessions[token].map { $0 > Date() } ?? false
    }

    func logout(headers: HTTPFields) {
        if let token = Self.cookie(in: headers) { sessions.removeValue(forKey: token) }
    }

    func invalidateSessions() { sessions.removeAll() }

    private func purgeExpired() {
        let now = Date()
        sessions = sessions.filter { $0.value > now }
    }

    private static func cookie(in headers: HTTPFields) -> String? {
        guard let raw = headers[HTTPField.Name("cookie")!] else { return nil }
        return raw.split(separator: ";").compactMap { part -> String? in
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == Substring(cookieName) else { return nil }
            return String(pieces[1])
        }.first
    }
}

struct AdminSessionResponse: Codable {
    var passwordConfigured: Bool
    var authenticated: Bool
}

struct AdminLoginRequest: Codable {
    var username: String?
    var password: String
}
