import Foundation
import Testing
@testable import CaritosNetworking

/// Routes requests by host so tests running in parallel do not share state.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (URLResponse, Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubProtocol.lock.lock()
        let handler = StubProtocol.handlers[request.url?.host ?? ""]
        StubProtocol.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

@Test func transportReturnsDataAndResponse() async throws {
    let url = URL(string: "https://ok.test/path")!
    StubProtocol.register(host: "ok.test") { request in
        (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data("hello".utf8))
    }
    let transport = URLSessionTransport(session: stubbedSession())
    let (data, response) = try await transport.send(URLRequest(url: url))
    #expect(data == Data("hello".utf8))
    #expect(response.statusCode == 201)
}

@Test func transportMapsNonHTTPResponseToInvalidResponse() async {
    let url = URL(string: "https://nonhttp.test/")!
    StubProtocol.register(host: "nonhttp.test") { request in
        (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
    }
    let transport = URLSessionTransport(session: stubbedSession())
    await #expect(throws: APIError.invalidResponse) {
        _ = try await transport.send(URLRequest(url: url))
    }
}

@Test func transportDoesNotThrowOnErrorStatus() async throws {
    let url = URL(string: "https://err.test/")!
    StubProtocol.register(host: "err.test") { request in
        (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
    }
    let (_, response) = try await URLSessionTransport(session: stubbedSession()).send(URLRequest(url: url))
    #expect(response.statusCode == 500)
}
