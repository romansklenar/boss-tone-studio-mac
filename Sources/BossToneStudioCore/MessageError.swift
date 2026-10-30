import Foundation

/// An error that is only its text, which is what the `500` body, a log line or the launch failure shows. Where the page
/// chose a part of it (a path, a URL, an extension), the text is not safe to log as it is: a caller logs it through
/// `escaped`, and a refusal's text is escaped where it is built.
public struct MessageError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    public var errorDescription: String? { description }
}
