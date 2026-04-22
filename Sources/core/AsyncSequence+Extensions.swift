// AsyncSequence+Extensions.swift
// core module
//
// Created for open-source cleanup: consolidates firstElement() extension
// that was previously duplicated across cli, mcp-core, mycelium-bin, and
// websocket-observer targets.

import Foundation

extension AsyncSequence {
    /// Returns the first element of the sequence, or `nil` if the sequence is empty.
    public func firstElement() async -> Element? {
        var iterator = makeAsyncIterator()
        return try? await iterator.next()
    }
}
