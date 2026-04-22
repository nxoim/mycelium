import ArgumentParser
import Foundation
import MCP
import core
import mcp_core

@main
struct MCPStdio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-stdio",
        abstract: "Start the Mycelium MCP server over stdio transport.",
        helpNames: [.short, .long]
    )

    @Flag(name: .long, help: "Use in-memory storage instead of persistent SQLite")
    var ramOnly = false

    @Option(name: .long, help: "Directory for the SQLite database (default: executable directory)")
    var db: String?

    func run() async throws {
        let config = MyceliumConfig(
            dbPath: db,
            ramOnly: ramOnly,
            transportMode: .stdio
        )

        let graphBox = try GraphFactory.make(config: config)
        let server = await MCPTransport.makeServer(graph: graphBox)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
