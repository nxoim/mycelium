import Foundation
import core

public struct GraphFactory {

    public static func make(config: MyceliumConfig) throws -> MemoryGraphBox {
        if config.ramOnly {
            return MemoryGraphBox(InMemoryMemoryGraph())
        }
        let graph = try LocalMemoryGraph(directory: config.databaseDirectory)
        return MemoryGraphBox(graph)
    }
}
