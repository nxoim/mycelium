import Foundation
import core

/// Shared factory for creating MemoryGraph instances.
/// Used by both stdio and HTTP MCP transports to avoid duplication.
public struct GraphFactory {

    /// Create a MemoryGraphBox from a MyceliumConfig.
    /// - Parameter config: The configuration to use.
    /// - Returns: A configured MemoryGraphBox ready for use.
    public static func make(config: MyceliumConfig) throws -> MemoryGraphBox {
        if config.ramOnly {
            return MemoryGraphBox(InMemoryMemoryGraph())
        }
        let graph = try LocalMemoryGraph(directory: config.databaseDirectory)
        return MemoryGraphBox(graph)
    }
}
