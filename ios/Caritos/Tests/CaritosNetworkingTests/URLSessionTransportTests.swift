import Foundation
import Testing
@testable import CaritosNetworking

/// Routes requests by host so tests running in parallel do not share state.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (URLResponse, Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var failures: [String: Error] = [:]
    private static let lock = NSLock()

    static func register(host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    /// Requests to `host` fail with `error` instead of returning a response.
    static func registerFailure(host: String, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        failures[host] = error
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubProtocol.lock.lock()
        let handler = StubProtocol.handlers[request.url?.host ?? ""]
        let failure = StubProtocol.failures[request.url?.host ?? ""]
        StubProtocol.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
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

@Test func transportWrapsAFailedRequestAsTransientNetworkError() async {
    let url = URL(string: "https://offline.test/")!
    StubProtocol.registerFailure(host: "offline.test", URLError(.notConnectedToInternet))
    await #expect {
        _ = try await URLSessionTransport(session: stubbedSession()).send(URLRequest(url: url))
    } throws: { error in
        guard let api = error as? APIError, case .network(let message) = api else { return false }
        return api.isTransient && !message.isEmpty
    }
}

@Test func transportPassesCancellationThroughUntouched() async {
    let url = URL(string: "https://cancelled.test/")!
    StubProtocol.registerFailure(host: "cancelled.test", URLError(.cancelled))
    await #expect {
        _ = try await URLSessionTransport(session: stubbedSession()).send(URLRequest(url: url))
    } throws: { error in
        (error as? URLError)?.code == .cancelled
    }
}

@Test func transportPassesTaskCancellationThroughUntouched() async {
    let url = URL(string: "https://ok-cancel.test/")!
    StubProtocol.register(host: "ok-cancel.test") { request in
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
    }
    let transport = URLSessionTransport(session: stubbedSession())
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await transport.send(URLRequest(url: url))
    }
    let result = await task.result
    guard case .failure(let error) = result else {
        Issue.record("a cancelled send must throw")
        return
    }
    #expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "got \(error)")
}
