import Foundation

public enum APIError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case server(status: Int, message: String?)
    case network(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "The server is not configured."
        case .unauthorized: "The server rejected the credentials."
        case .server(let status, let message):
            if let message { "Server error \(status): \(message)" } else { "Server error \(status)." }
        case .network(let message): "Network problem: \(message)"
        case .invalidResponse: "Unexpected response from the server."
        }
    }

    /// Worth retrying automatically, as opposed to needing the user to act. Deliberately wider than 5xx
    /// (ported from caritos-com): 408, 429, network failures and malformed responses count too.
    public var isTransient: Bool {
        switch self {
        case .network, .invalidResponse: true
        case .server(let status, _): status >= 500 || status == 408 || status == 429
        case .notConfigured, .unauthorized: false
        }
    }

    /// Passes 2xx, throws `.unauthorized` for 401 and `.server` for anything else. The message is
    /// the `error` field of a JSON body when there is one; the body is never put in the error otherwise.
    public static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.server(status: response.statusCode, message: message)
        }
    }

    private struct ErrorBody: Decodable { let error: String }
}
