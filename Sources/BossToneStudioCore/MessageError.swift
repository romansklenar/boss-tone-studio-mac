import Foundation

/// An error that is only its text: the `500` body, a log line or a launch failure.
public struct MessageError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    public var errorDescription: String? { description }
}
