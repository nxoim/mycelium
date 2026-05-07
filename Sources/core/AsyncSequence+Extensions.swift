import Foundation

extension AsyncSequence {
    public func firstElement() async -> Result<Element?, Error> {
        var iterator = makeAsyncIterator()
        do {
            let first = try await iterator.next()
            return .success(first)
        } catch {
            return .failure(error)
        }
    }

    /// For streams yielding `Result<Value, MemoryError>`. Returns the first successful value,
    /// or propagates the first error.
    public func firstResult<Value>() async -> Result<Value, MemoryError>
    where Element == Result<Value, MemoryError> {
        var iterator = makeAsyncIterator()
        while let result = try? await iterator.next() {
            switch result {
            case .success(let value):
                return .success(value)
            case .failure(let error):
                return .failure(error)
            }
        }
        return .failure(MemoryError.graphError("Stream yielded no Results"))
    }
}

extension MemoryError {
    static func graphError(_ message: String) -> MemoryError {
        .storageFailed(message)
    }
}
