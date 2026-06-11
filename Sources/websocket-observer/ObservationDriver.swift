import Foundation
import GRDB
import Logging
import core

private let logger = Logger(label: "com.nxoim.mycelium.observation")

actor ObservationDriver {
    private let dbQueue: DatabaseQueue
    private let wsManager: WebSocketManager
    private var cancellable: AnyDatabaseCancellable?

    init(dbQueue: DatabaseQueue, wsManager: WebSocketManager) {
        self.dbQueue = dbQueue
        self.wsManager = wsManager
    }

    func start() {
        let observation = ValueObservation.tracking { db -> Int in
            let request = SQLRequest<Int>("SELECT COUNT(*) FROM nodes")
            return try Int.fetchOne(db, request) ?? 0
        }

        cancellable = observation.start(
            in: dbQueue,
            onError: { (error: Error) in
                logger.error("Observation error: \(error)")
            },
            onChange: { (_: Int) in
                // DB changed — specific events are emitted via MemoryGraphBox callback hooks
            }
        )
    }

    func recordMemorized(ids: [UUID]) {
        Task {
            await wsManager.broadcast(.memorized(ids: ids))
        }
    }

    func recordForgotten(ids: [UUID]) {
        Task {
            await wsManager.broadcast(.forgotten(ids: ids))
        }
    }

    func recordAssociated(id: UUID, with: [UUID]) {
        Task {
            await wsManager.broadcast(.associated(id: id, with: with))
        }
    }

    func recordDissociated(id: UUID, from: [UUID]) {
        Task {
            await wsManager.broadcast(.dissociated(id: id, from: from))
        }
    }

    func recordImported() {
        Task {
            await wsManager.broadcast(.imported)
        }
    }
}
