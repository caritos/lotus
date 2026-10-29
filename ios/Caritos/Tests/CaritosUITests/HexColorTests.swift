import Testing
@testable import CaritosUI

@Test func orangeSplitsIntoComponents() {
    let c = HexColor.components(0xFF8000)
    #expect(c.red == 1.0)
    #expect(c.green == 128.0 / 255.0)
    #expect(c.blue == 0.0)
}

@Test func blackIsAllZeros() {
    let c = HexColor.components(0x000000)
    #expect(c.red == 0 && c.green == 0 && c.blue == 0)
}

@Test func whiteIsAllOnes() {
    let c = HexColor.components(0xFFFFFF)
    #expect(c.red == 1 && c.green == 1 && c.blue == 1)
}
