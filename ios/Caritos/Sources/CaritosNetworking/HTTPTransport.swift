import Foundation

/// The seam between a client and the network, so tests can stub HTTP.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
