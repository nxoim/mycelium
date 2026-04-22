import Foundation

enum Subscription: Hashable, Sendable {
    case all
    case memory(UUID)
    case search(keywords: [String])
}
