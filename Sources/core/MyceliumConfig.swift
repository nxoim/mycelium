import Foundation

public enum DatabaseConfig {
    public static let defaultFileName = "mycelium.sqlite"
}

public struct MyceliumConfig: Sendable {

    public let dbPath: String?
    public let ramOnly: Bool

    public enum TransportMode: Sendable {
        case stdio
        case http(host: String, port: Int)
    }

    public let transportMode: TransportMode?

    public enum LogLevel: Sendable {
        case debug
        case info
        case warning
        case error
    }

    public let logLevel: LogLevel

    public init(
        dbPath: String? = nil,
        ramOnly: Bool = false,
        transportMode: TransportMode? = nil,
        logLevel: LogLevel = .info
    ) {
        self.dbPath = dbPath
        self.ramOnly = ramOnly
        self.transportMode = transportMode
        self.logLevel = logLevel
    }

    public var databaseDirectory: URL {
        if let dbPath {
            return URL(fileURLWithPath: dbPath)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
    }

    public var databaseURL: URL {
        databaseDirectory.appendingPathComponent(DatabaseConfig.defaultFileName)
    }
}
