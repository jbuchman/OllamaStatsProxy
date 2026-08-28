import Foundation

struct VirtualModel: Codable, Equatable, Sendable {
    var name: String
    var flowID: String
    var enabled: Bool = true
}

struct AppConfiguration: Codable, Equatable, Sendable {
    var webSearchProvider: WebTools.SearchProvider?
    var webSearchAPIKey: String?
    var webSearchURL: String?
    var webFetchMaxBytes: Int
    var webFetchMaxCharacters: Int
    var webFetchEnabled: Bool?
    var webFetchAllowPrivateNetworks: Bool?
    var serverToolsEnabled: Bool
    var serverToolRounds: Int
    var adminPasswordHash: String?
    var langflowURL: String?
    var langflowAPIKey: String?
    var virtualModels: [VirtualModel]?
}

struct ConfigurationView: Codable, Sendable {
    var webSearchProvider: WebTools.SearchProvider?
    var webSearchAPIKeyConfigured: Bool
    var webSearchURL: String?
    var webFetchMaxMB: Int
    var webFetchMaxCharacters: Int
    var webFetchEnabled: Bool
    var webFetchAllowPrivateNetworks: Bool
    var serverToolsEnabled: Bool
    var serverToolRounds: Int
    var restartRequired: Bool
    var adminPasswordConfigured: Bool
    var langflowURL: String?
    var langflowAPIKeyConfigured: Bool
    var virtualModels: [VirtualModel]
}

struct ConfigurationUpdate: Codable, Sendable {
    var webSearchProvider: WebTools.SearchProvider?
    var webSearchAPIKey: String?
    var clearWebSearchAPIKey: Bool?
    var webSearchURL: String?
    var webFetchMaxMB: Int
    var webFetchMaxCharacters: Int
    var webFetchEnabled: Bool
    var webFetchAllowPrivateNetworks: Bool
    var serverToolsEnabled: Bool
    var serverToolRounds: Int
    var adminPassword: String?
    var langflowURL: String?
    var langflowAPIKey: String?
    var clearLangflowAPIKey: Bool?
    var virtualModels: [VirtualModel]?
}

actor ConfigurationFile {
    private let path: String
    private var configuration: AppConfiguration

    init(path: String, defaults: AppConfiguration, adminPasswordOverride: String? = nil) throws {
        self.path = path
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            configuration = try decoder.decode(AppConfiguration.self, from: data)
        } else {
            configuration = defaults
            try Self.write(defaults, to: path)
        }
        if let password = adminPasswordOverride, !password.isEmpty,
           configuration.adminPasswordHash.map({ PasswordHasher.verify(password, encoded: $0) }) != true {
            configuration.adminPasswordHash = PasswordHasher.hash(password)
            try Self.write(configuration, to: path)
        }
    }

    func value() -> AppConfiguration { configuration }

    func view() -> ConfigurationView {
        ConfigurationView(
            webSearchProvider: configuration.webSearchProvider,
            webSearchAPIKeyConfigured: !(configuration.webSearchAPIKey?.isEmpty ?? true),
            webSearchURL: configuration.webSearchURL,
            webFetchMaxMB: configuration.webFetchMaxBytes / (1024 * 1024),
            webFetchMaxCharacters: configuration.webFetchMaxCharacters,
            webFetchEnabled: configuration.webFetchEnabled != false,
            webFetchAllowPrivateNetworks: configuration.webFetchAllowPrivateNetworks == true,
            serverToolsEnabled: configuration.serverToolsEnabled,
            serverToolRounds: configuration.serverToolRounds,
            restartRequired: false,
            adminPasswordConfigured: !(configuration.adminPasswordHash?.isEmpty ?? true),
            langflowURL: configuration.langflowURL,
            langflowAPIKeyConfigured: !(configuration.langflowAPIKey?.isEmpty ?? true),
            virtualModels: configuration.virtualModels ?? []
        )
    }

    func update(_ update: ConfigurationUpdate) throws -> ConfigurationView {
        configuration.webSearchProvider = update.webSearchProvider
        if update.clearWebSearchAPIKey == true {
            configuration.webSearchAPIKey = nil
        } else if let key = update.webSearchAPIKey, !key.isEmpty {
            configuration.webSearchAPIKey = key
        }
        configuration.webSearchURL = update.webSearchURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        configuration.webFetchMaxBytes = min(max(update.webFetchMaxMB, 1), 512) * 1024 * 1024
        configuration.webFetchMaxCharacters = min(max(update.webFetchMaxCharacters, 1_000), 1_000_000)
        configuration.webFetchEnabled = update.webFetchEnabled
        configuration.webFetchAllowPrivateNetworks = update.webFetchAllowPrivateNetworks
        configuration.serverToolsEnabled = update.serverToolsEnabled
        configuration.serverToolRounds = min(max(update.serverToolRounds, 1), 20)
        if let password = update.adminPassword, !password.isEmpty {
            configuration.adminPasswordHash = PasswordHasher.hash(password)
        }
        configuration.langflowURL = update.langflowURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if update.clearLangflowAPIKey == true {
            configuration.langflowAPIKey = nil
        } else if let key = update.langflowAPIKey, !key.isEmpty {
            configuration.langflowAPIKey = key
        }
        if let models = update.virtualModels {
            var seen = Set<String>()
            configuration.virtualModels = models.compactMap { model in
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let flowID = model.flowID.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = name.lowercased()
                guard !name.isEmpty, !flowID.isEmpty, seen.insert(key).inserted else { return nil }
                return VirtualModel(name: name, flowID: flowID, enabled: model.enabled)
            }
        }
        try Self.write(configuration, to: path)
        return view()
    }

    private static func write(_ configuration: AppConfiguration, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
