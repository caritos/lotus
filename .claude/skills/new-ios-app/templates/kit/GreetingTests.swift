import Testing
@testable import __APP__Kit

@Test func greetsByName() {
    #expect(Greeting.message(for: "Eladio") == "Hello, Eladio")
}

@Test func blankNameFallsBack() {
    #expect(Greeting.message(for: "  ") == "Hello")
}
