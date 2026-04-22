import Foundation
import MCP
import core

/// Shared MCP server setup for stdio and HTTP transports.
/// Avoids duplication between mcp-server and mcp-stdio executables.
public struct MCPTransport {

    public static func makeServer(
        graph: MemoryGraphBox,
        name: String = "mycelium-mcp",
        version: String = "1.0.0",
        instructions: String? = nil
    ) async -> Server {
        let server = Server(
            name: name,
            version: version,
            instructions: instructions ?? """
                You have a memory system. You can remember, forget, and associate memories. Use the available tools to manage your knowledge base.
                """,
            capabilities: .init(tools: .init(listChanged: true))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: mcpTools)
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            await handleTool(graph: graph, parameters: parameters)
        }

        return server
    }
}
