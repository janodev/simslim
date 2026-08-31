@testable import SimSlimCLI
import Testing

@Test func cliTargetLoads() {
    #expect(true)
}

@Test func truncatePreservesUnicode() {
    #expect(truncated("模拟器名称", to: 4) == "模拟器…")
    #expect(truncated("short", to: 10) == "short")
}

@Test func humanByteFormatting() {
    #expect(humanBytes(8 << 10) == "8 KB")
    #expect(compactBytes(0) == "0B")
    #expect(compactBytes(1_536) == "1.5K")
    #expect(compactBytes(3 * (1 << 30) + (1 << 29)) == "3.5G")
}

@Test func dottedVersionsCompareNumerically() {
    #expect(versionIsLess("9.0", "26.4"))
    #expect(versionIsLess("26.4", "26.10"))
    #expect(versionIsLess("18", "18.3"))
    #expect(!versionIsLess("18.3", "18.3"))
}
