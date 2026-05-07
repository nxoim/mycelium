import Foundation
import MCP
import core

public struct MCPTransport {

    private static let defaultInstructions = """
        You have a memory system. You can remember, forget, and associate memories. Use the available tools to manage your knowledge base.
        """

    public static func makeServer(
        graph: MemoryGraphBox,
        name: String = "mycelium-mcp",
        version: String = "1.0.0",
        instructions: String? = nil
    ) async -> Server {
        let server = Server(
            name: name,
            version: version,
            instructions: instructions ?? defaultInstructions,
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
