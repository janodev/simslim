import SimSlimCore
import Testing

@Suite("Profile verification")
struct VerificationTests {
    @Test(
        "disabled-state comparison reports managed drift",
        arguments: [
            VerificationCase(
                disabled: ["a", "b"],
                desired: ["a", "b"],
                expected: VerifyResult(ok: true)
            ),
            VerificationCase(
                disabled: [],
                desired: ["a", "b"],
                expected: VerifyResult(missing: ["a", "b"])
            ),
            VerificationCase(
                disabled: ["a", "c"],
                desired: ["a", "b"],
                expected: VerifyResult(missing: ["b"], extra: ["c"])
            ),
            VerificationCase(
                disabled: ["a", "com.example.other"],
                desired: ["a"],
                expected: VerifyResult(ok: true)
            ),
            VerificationCase(
                disabled: [],
                desired: [],
                expected: VerifyResult(ok: true)
            ),
        ]
    )
    func compareManagedDisabledState(testCase: VerificationCase) {
        let result = compareDisabled(
            disabled: testCase.disabled,
            desired: testCase.desired,
            managed: ["a", "b", "c", "d"]
        )
        #expect(result == testCase.expected)
    }

    @Test("missing labels are sorted")
    func missingLabelsAreSorted() {
        let result = compareDisabled(
            disabled: [],
            desired: ["z", "a", "m"],
            managed: ["z", "a", "m"]
        )
        #expect(result.missing == ["a", "m", "z"])
    }
}

struct VerificationCase: CustomTestStringConvertible, Sendable {
    let disabled: Set<String>
    let desired: Set<String>
    let expected: VerifyResult

    var testDescription: String {
        "disabled=\(disabled.sorted()), desired=\(desired.sorted())"
    }
}
