//
//  HTTP.swift
//  DropPortalCore
//
//  The smallest HTTP/1.1 the phone page needs: one request per connection,
//  a head parsed from bytes, and a response written back. No keep-alive, no
//  chunked bodies.
//

import Foundation

/// A parsed request line and headers. Header names are lowercased.
public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]

    /// The declared body length, `nil` when absent. Invalid values are a parse
    /// error, not `nil`.
    public var contentLength: Int64? {
        headers["content-length"].flatMap { Int64($0) }
    }

    public enum ParseError: Error, Equatable {
        case tooLarge, malformed
    }

    /// Longest head accepted, request line and headers together.
    public static let maxHeadBytes = 16 * 1024

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Looks for a complete head at the start of `buffer`.
    ///
    /// Returns `nil` while more bytes are needed, or the head with how many
    /// bytes it used (the body starts right after).
    public static func parse(_ buffer: Data) throws -> (head: HTTPRequestHead, consumed: Int)? {
        guard let end = buffer.range(of: terminator) else {
            if buffer.count > maxHeadBytes { throw ParseError.tooLarge }
            return nil
        }
        let headBytes = buffer[buffer.startIndex..<end.lowerBound]
        guard headBytes.count <= maxHeadBytes,
              let text = String(data: headBytes, encoding: .utf8) else {
            throw headBytes.count > maxHeadBytes ? ParseError.tooLarge : ParseError.malformed
        }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
              parts[1].hasPrefix("/") else { throw ParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { throw ParseError.malformed }
            // Two different lengths is request smuggling; refuse it.
            if name == "content-length", let old = headers[name], old != value { throw ParseError.malformed }
            headers[name] = value
        }
        if let length = headers["content-length"] {
            guard let n = Int64(length), n >= 0 else { throw ParseError.malformed }
        }
        if headers["transfer-encoding"] != nil { throw ParseError.malformed }

        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let head = HTTPRequestHead(
            method: String(parts[0]),
            path: String(pieces[0]),
            query: pieces.count > 1 ? parseQuery(String(pieces[1])) : [:],
            headers: headers
        )
        return (head, buffer.distance(from: buffer.startIndex, to: end.upperBound))
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            let value = kv.count > 1
                ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                : ""
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

/// A response with its whole body in memory: the page, or a short JSON line.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var extraHeaders: [(String, String)] = []

    public init(status: Int, contentType: String = "text/plain; charset=utf-8", body: Data,
                extraHeaders: [(String, String)] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    public static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(message.utf8))
    }

    public static func json(_ status: Int, _ object: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    public func serialized() -> Data {
        Self.head(status: status, contentType: contentType, length: Int64(body.count), extraHeaders: extraHeaders) + body
    }

    /// The status line and headers alone, for a body streamed after them.
    public static func head(status: Int, contentType: String, length: Int64, extraHeaders: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }
}
