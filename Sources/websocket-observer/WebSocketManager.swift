import Foundation
import HummingbirdWebSocket
import core

actor WebSocketManager {
    struct Connection: Identifiable, Sendable {
        let id: UUID
        var subscriptions: Set<Subscription> = []
        let outbound: WebSocketOutboundWriter
    }

    private var connections: [Connection.ID: Connection] = [:]

    func register(outbound: WebSocketOutboundWriter, id: Connection.ID) {
        let conn = Connection(id: id, outbound: outbound)
        connections[id] = conn
    }

    func unregister(_ id: Connection.ID) {
        connections.removeValue(forKey: id)
    }

    func subscribe(_ id: Connection.ID, to subscription: Subscription) {
        connections[id]?.subscriptions.insert(subscription)
    }

    func unsubscribe(_ id: Connection.ID, from subscription: Subscription) {
        connections[id]?.subscriptions.remove(subscription)
    }

    func unsubscribeAll(_ id: Connection.ID) {
        connections[id]?.subscriptions.removeAll()
    }

    func broadcast(_ event: MemoryEvent) {
        let payload = event.encodeToJSON()
        for connection in connections.values {
            sendToConnection(connection, payload: payload)
        }
    }

    func broadcastToSubscribed(_ event: MemoryEvent) {
        let payload = event.encodeToJSON()
        for connection in connections.values {
            for subscription in connection.subscriptions {
                if event.matches(subscription: subscription) {
                    sendToConnection(connection, payload: payload)
                    break
                }
            }
        }
    }

    func send(_ id: Connection.ID, _ event: MemoryEvent) {
        let payload = event.encodeToJSON()
        if let connection = connections[id] {
            sendToConnection(connection, payload: payload)
        }
    }

    private func sendToConnection(_ connection: Connection, payload: String) {
        Task { [weak self] in
            do {
                try await connection.outbound.write(.text(payload))
            } catch {
                await self?.unregister(connection.id)
            }
        }
    }
}

extension MemoryEvent {
    func matches(subscription: Subscription) -> Bool {
        switch (self, subscription) {
        case (.memorized, .all), (.forgotten, .all), (.associated, .all),
            (.dissociated, .all), (.imported, .all), (.graphState, .all):
            return true
        case (.memorized(let ids), .memory(let id)):
            return ids.contains(id)
        case (.forgotten(let ids), .memory(let id)):
            return ids.contains(id)
        case (.associated(let id, _), .memory(let target)):
            return id == target
        case (.dissociated(let id, _), .memory(let target)):
            return id == target
        case (.searchUpdated(let keywords), .search(let subKeywords)):
            return keywords == subKeywords
        default:
            return false
        }
    }
}
