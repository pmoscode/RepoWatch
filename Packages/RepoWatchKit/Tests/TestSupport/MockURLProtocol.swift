import Foundation
import Synchronization

/// Thread-sicherer Wert für Zähler und Aufzeichnungen in Tests.
public final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    public init(_ value: Value) { mutex = Mutex(value) }
    public var value: Value { mutex.withLock { $0 } }
    @discardableResult
    public func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// Beantwortet Anfragen aus einem Test-Handler statt aus dem Netz.
///
/// Jede Session bekommt einen eigenen Host (`https://<uuid>.mock`), damit parallel laufende
/// Tests sich nicht gegenseitig die Handler überschreiben.
public final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlers = Locked<[String: Handler]>([:])

    /// Neue Session samt Basis-URL, deren Anfragen an `handler` gehen.
    public static func makeSession(handler: @escaping Handler) -> (session: URLSession, baseURL: URL) {
        let host = "\(UUID().uuidString.lowercased()).mock"
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        return (URLSession(configuration: configuration), URL(string: "https://\(host)")!)
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let host = request.url?.host(), let handler = Self.handlers.value[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}
}

public extension HTTPURLResponse {
    static func make(_ status: Int, for request: URLRequest, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

public extension URLRequest {
    /// Body der Anfrage; URLSession reicht ihn an URLProtocol oft nur als Stream weiter.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Formular-Felder eines `application/x-www-form-urlencoded`-Bodys.
    var formFields: [String: String] {
        guard let body = bodyData, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }
}

/// Zeichnet Wartezeiten auf, statt wirklich zu warten.
public final class SleepRecorder: Sendable {
    private let recorded = Locked<[Duration]>([])
    public init() {}
    public var durations: [Duration] { recorded.value }
    public var sleeper: @Sendable (Duration) async throws -> Void {
        { [recorded] duration in recorded.withLock { $0.append(duration) } }
    }
}
