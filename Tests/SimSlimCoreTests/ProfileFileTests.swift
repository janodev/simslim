import Foundation
import SimSlimCore
import Testing

@Suite("Profile files")
struct ProfileFileTests {
    @Test("load a complete profile")
    func loadProfile() throws {
        let path = try writeProfile(
            """
            {
              "name": "ci",
              "description": "UI test runs",
              "except": ["search", "store"],
              "keep": ["com.apple.apsd"]
            }
            """
        )
        let profile = try loadSlimProfile(at: path)
        #expect(profile.exceptCategories == ["search", "store"])
        #expect(profile.keep == ["com.apple.apsd"])
    }

    @Test("minimal profile selects no exceptions")
    func loadMinimalProfile() throws {
        let profile = try loadSlimProfile(at: writeProfile("{}"))
        #expect(profile.exceptCategories.isEmpty)
        #expect(profile.keep.isEmpty)
    }

    @Test(
        "invalid profiles are rejected",
        arguments: [
            #"{"except":["nope"]}"#,
            #"{"keep":["com.apple.does-not-exist"]}"#,
            #"{"disable":["search"]}"#,
            #"{"except":["#,
        ]
    )
    func rejectInvalidProfile(contents: String) throws {
        let path = try writeProfile(contents)
        #expect(throws: SimSlimDomainError.self) {
            try loadSlimProfile(at: path)
        }
    }

    @Test("missing profile file is reported")
    func missingProfile() {
        let path = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "profile.json")
            .path
        #expect(throws: SimSlimDomainError.self) {
            try loadSlimProfile(at: path)
        }
    }

    @Test("flags build a profile")
    func flagsBuildProfile() throws {
        let profile = try buildProfile(
            profilePath: "",
            except: "search",
            keep: "com.apple.apsd"
        )
        #expect(profile.exceptCategories == ["search"])
        #expect(profile.keep == ["com.apple.apsd"])
    }

    @Test("unknown category flag is rejected")
    func unknownCategoryFlag() {
        #expect(throws: SimSlimDomainError.self) {
            try buildProfile(profilePath: "", except: "nope", keep: "")
        }
    }

    @Test("profile file resolves through buildProfile")
    func fileBuildsProfile() throws {
        let path = try writeProfile(#"{"except":["search"]}"#)
        let profile = try buildProfile(profilePath: path, except: "", keep: "")
        #expect(profile.exceptCategories == ["search"])
    }

    @Test("profile file cannot be combined with selection flags")
    func profileAndFlagsAreExclusive() {
        #expect(throws: SimSlimDomainError.self) {
            try buildProfile(profilePath: "some.json", except: "search", keep: "")
        }
        #expect(throws: SimSlimDomainError.self) {
            try buildProfile(
                profilePath: "some.json",
                except: "",
                keep: "com.apple.apsd"
            )
        }
    }

    @Test(
        "profile filenames are normalized",
        arguments: [
            ProfileFileNameCase(name: "ci", expected: "ci.json"),
            ProfileFileNameCase(name: "UI Test Runs", expected: "ui-test-runs.json"),
            ProfileFileNameCase(name: "", expected: "profile.json"),
            ProfileFileNameCase(name: "  ", expected: "profile.json"),
            ProfileFileNameCase(name: "prod.json", expected: "prod.json"),
            ProfileFileNameCase(name: "a/b:c", expected: "a-b-c.json"),
            ProfileFileNameCase(name: "--weird--", expected: "weird.json"),
        ]
    )
    func normalizeProfileFileName(testCase: ProfileFileNameCase) {
        #expect(profileFileName(testCase.name) == testCase.expected)
    }

    @Test("profile JSON is deterministic, sparse, and newline terminated")
    func marshalProfileJSON() throws {
        let data = try marshalProfile(
            SlimProfile(name: "ci", except: ["search"], keep: ["com.apple.apsd"])
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        #expect(!text.contains("description"))
        #expect(try marshalProfile(SlimProfile()) == Data("{}\n".utf8))
        #expect(data == (try marshalProfile(
            SlimProfile(name: "ci", except: ["search"], keep: ["com.apple.apsd"])
        )))
    }

    @Test("comma-separated lists trim and drop blank entries")
    func splitCommaSeparatedList() {
        #expect(splitList(" search, ,store,, web ") == ["search", "store", "web"])
    }

    private func writeProfile(_ contents: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swift-simslim-tests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appending(path: "profile.json")
        try Data(contents.utf8).write(to: file)
        return file.path
    }
}

struct ProfileFileNameCase: CustomTestStringConvertible, Sendable {
    let name: String
    let expected: String

    var testDescription: String { name.isEmpty ? "empty" : name }
}
