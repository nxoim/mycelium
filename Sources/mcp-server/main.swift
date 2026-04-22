import ArgumentParser
import Foundation
import Hummingbird
import MCP
import core
import mcp_core

@main
struct MCPServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-server",
        abstract: "Start the Mycelium MCP server over HTTP transport.",
        helpNames: [.short, .long]
    )

    @Flag(name: .long, help: "Use in-memory storage instead of persistent SQLite")
    var ramOnly = false

    @Option(
        name: .long, help: "Path to the SQLite database directory (default: executable directory)")
    var db: String?

    @Option(
        name: .long,
        help: "Host and port to bind for HTTP (format: host:port, default: 127.0.0.1:3000)"
    )
    var httpHost: String?

    func run() async throws {
        let host = httpHost?.split(separator: ":").first.map(String.init) ?? "127.0.0.1"
        let port = httpHost?.split(separator: ":").last.flatMap { Int($0) } ?? 3000
        let transportMode = MyceliumConfig.TransportMode.http(host: host, port: port)
        let config = MyceliumConfig(
            dbPath: db,
            ramOnly: ramOnly,
            transportMode: transportMode
        )

        let graphBox = try GraphFactory.make(config: config)
        let server = await MCPTransport.makeServer(graph: graphBox)
        let transport = StatelessHTTPServerTransport()

        let router = Router()
        router.post("/mcp") { request, _ in
            try await handleMCPRequest(
                graphBox: graphBox, transport: transport, request: request)
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        let address = "\(app.configuration.address)"
        print("MCP server running on \(address)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.start(transport: transport) }
            group.addTask { try await app.run() }
            try await group.waitForAll()
        }
    }
}
