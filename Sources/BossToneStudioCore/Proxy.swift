import Foundation
import os

public enum ProxyResult: Sendable, Equatable {
    case response(status: Int, contentType: String, body: Data)
    case refused(String)
    case failed(String)
}

public protocol ProxyFetching: Sendable {
    func fetch(_ url: String) async -> ProxyResult
}

/// A URL the proxy will not fetch; the text is safe to log (page-chosen parts go through `escaped`).
public struct ProxyRefusal: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Fetches Tone Central's remote resources for the page; Roland's servers send no CORS headers, so the page can't.
///
/// Only the hosts Tone Central uses are reachable, over HTTPS, and redirects are held to the same list, so the proxy
/// cannot be turned against other hosts. Roland's own hosts must answer with JSON (ADR-0003, weak points).
public struct Proxy: ProxyFetching {
    public static let allowedHosts: Set<String> = [
        "api.roland.com",  // URL definitions (katana_mk2.json)
        "bosstonecentral.com",  // liveset catalogue and .tsl files
        "www.youtube.com",  // iframe API for preview videos
    ]
    static let timeout: TimeInterval = 20
    static let userAgent = "Mozilla/5.0 (Macintosh)"

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        session = URLSession(configuration: configuration)
    }

    /// The URL rebuilt from `https`, the allowlisted host name, path and query only: userinfo, port and fragment are
    /// dropped, so nothing the page sends besides path and query reaches the request.
    public static func checkedURL(_ url: String) throws -> URL {
        guard let parts = URLComponents(string: url, encodingInvalidCharacters: true),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host?.lowercased(), allowedHosts.contains(host)
        else { throw ProxyRefusal(description: "refusing to proxy \(escaped(url))") }
        var rebuilt = URLComponents()
        rebuilt.scheme = "https"
        rebuilt.host = host
        rebuilt.percentEncodedPath = parts.percentEncodedPath
        rebuilt.percentEncodedQuery = parts.percentEncodedQuery
        guard let checked = rebuilt.url, checked.host == host else {
            throw ProxyRefusal(description: "refusing to proxy \(escaped(url))")
        }
        return checked
    }

    public func fetch(_ url: String) async -> ProxyResult {
        let target: URL
        do {
            target = try Self.checkedURL(url)
        } catch {
            return .refused("\(error)")
        }
        var request = URLRequest(url: target, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let redirects = AllowlistedRedirects()
        do {
            let (body, response) = try await session.data(for: request, delegate: redirects)
            if let refusal = redirects.refusal { return .refused(refusal) }
            guard let http = response as? HTTPURLResponse, let host = http.url?.host?.lowercased() else {
                return .failed("proxy \(escaped(url)) failed: no HTTP response")
            }
            // The delegate already held every hop to the list; this keeps gate from ever seeing another host.
            guard Self.allowedHosts.contains(host) else { return .refused("refusing to proxy \(escaped(url))") }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            return Self.gate(host: host, status: http.statusCode, contentType: contentType, body: body)
        } catch {
            if let refusal = redirects.refusal { return .refused(refusal) }
            return .failed("proxy \(escaped(url)) failed: \(error.localizedDescription)")
        }
    }

    /// Roland's hosts are held to JSON, and their bodies leave as `application/json` only when Roland said so, else as
    /// `text/plain`: jQuery then never evaluates them as script or HTML. Relabelling everything as JSON would break
    /// `.tsl` files, which come as `binary/octet-stream` and which the page parses with `JSON.parse` itself.
    /// Only YouTube's player scripts pass unchanged; an unlisted host is held to JSON too, so this fails closed.
    public static func gate(host: String, status: Int, contentType: String, body: Data) -> ProxyResult {
        let plain = "text/plain; charset=utf-8"
        if host.lowercased() == "www.youtube.com" {
            return .response(status: status, contentType: contentType, body: body)
        }
        guard (200..<300).contains(status) else { return .response(status: status, contentType: plain, body: Data()) }
        do {
            _ = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            return .failed("\(host) response is not JSON")
        }
        let type = contentType.lowercased().contains("json") ? "application/json" : plain
        return .response(status: status, contentType: type, body: body)
    }
}

/// Holds redirects to the allowlist and sends them to the rebuilt URL. A refused redirect is remembered, because
/// URLSession then delivers the redirect response itself as if it were the answer.
final class AllowlistedRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let refused = OSAllocatedUnfairLock<String?>(initialState: nil)

    var refusal: String? { refused.withLock { $0 } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let target = request.url?.absoluteString ?? ""
        do {
            var next = request
            next.url = try Proxy.checkedURL(target)
            next.setValue(Proxy.userAgent, forHTTPHeaderField: "User-Agent")
            return next
        } catch {
            refused.withLock { $0 = "refusing redirect to \(escaped(target))" }
            return nil
        }
    }
}
