import Foundation
import Testing
@testable import CaritosNetworking

private func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

@Test(arguments: [200, 201, 204, 299])
func checkPassesSuccess(status: Int) throws {
    try APIError.check(Data(), response(status))
}

@Test func checkThrowsUnauthorizedFor401() {
    #expect(throws: APIError.unauthorized) { try APIError.check(Data(), response(401)) }
}

@Test func checkUsesJSONErrorMessage() {
    let body = Data(#"{"error":"title is required"}"#.utf8)
    #expect(throws: APIError.server(status: 422, message: "title is required")) {
        try APIError.check(body, response(422))
    }
}

@Test func checkHasNilMessageWithoutJSONBody() {
    #expect(throws: APIError.server(status: 500, message: nil)) { try APIError.check(Data("oops".utf8), response(500)) }
    #expect(throws: APIError.server(status: 404, message: nil)) { try APIError.check(Data(), response(404)) }
}

@Test func checkThrowsServerForRedirectStatus() {
    #expect(throws: APIError.server(status: 302, message: nil)) { try APIError.check(Data(), response(302)) }
}

@Test func transientClassification() {
    #expect(APIError.network("offline").isTransient)
    #expect(APIError.server(status: 500, message: nil).isTransient)
    #expect(APIError.server(status: 503, message: "x").isTransient)
    #expect(!APIError.unauthorized.isTransient)
    #expect(!APIError.server(status: 400, message: nil).isTransient)
    #expect(!APIError.server(status: 404, message: nil).isTransient)
    #expect(!APIError.notConfigured.isTransient)
}
