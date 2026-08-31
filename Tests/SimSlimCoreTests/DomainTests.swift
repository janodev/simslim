import Foundation
import SimSlimCore
import Testing

@Suite("Profile domain")
struct DomainTests {
    private let forbiddenLabels: Set<String> = [
        "com.apple.nanoregistryd",
        "com.apple.nanoregistrylaunchd",
        "com.apple.nanoprefsyncd.2",
        "com.apple.nanotimekitcompaniond",
        "com.apple.nanobackupd",
        "com.apple.sleepd",
        "com.apple.appprotectiond",
        "com.apple.ManagedSettingsAgent",
        "com.apple.managedconfiguration.profiled",
        "com.apple.mobiletimerd",
        "com.apple.routined",
        "com.apple.biomed",
        "com.apple.biomesyncd",
        "com.apple.dmd",
        "com.apple.donotdisturbd",
    ]

    @Test("managed labels exclude services known to break boot")
    func managedExcludesForbidden() {
        #expect(managedSet().isDisjoint(with: forbiddenLabels))
    }

    @Test("full profile does not claim unmanaged processes")
    func fullProfileExcludesUnmanagedProcesses() {
        let desired = Profile().desired()
        for label in [
            "com.apple.routined",
            "com.apple.sharingd",
            "com.apple.locationd",
            "com.apple.eventkitsyncd",
            "com.apple.Spotlight",
            "com.apple.MercuryPoster",
            "com.apple.texttospeech.SiriAUSP",
        ] {
            #expect(!desired.contains(label))
        }
    }

    @Test("labels do not repeat inside a category")
    func noDuplicateLabelsWithinCategory() {
        for category in categories {
            #expect(Set(category.labels).count == category.labels.count)
        }
    }

    @Test("excepted categories preserve all shared labels")
    func exceptedCategoriesKeepSharedLabels() {
        var owners: [String: [String]] = [:]
        for category in categories {
            for label in category.labels {
                owners[label, default: []].append(category.id)
            }
        }

        let shared = owners.filter { $0.value.count > 1 }
        #expect(!shared.isEmpty)
        for (label, categoryIDs) in shared {
            for categoryID in categoryIDs {
                let profile = Profile(exceptCategories: [categoryID])
                #expect(!profile.desired().contains(label))
            }
        }
    }

    @Test("every managed service has one concise description")
    func everyServiceHasDescription() {
        var known: Set<String> = []
        for category in categories {
            #expect(category.serviceDescriptions.count == category.labels.count)
            for label in category.labels {
                known.insert(label)
                let description = category.serviceDescriptions[label] ?? ""
                #expect(!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!description.contains("\n"))
                #expect(!description.contains("\r"))
                #expect(description.count <= 90)
            }
        }
        #expect(Set(serviceDescriptionByLabel.keys) == known)
    }

    @Test("repair-only services are managed but never slimmable")
    func alwaysEnabledServicesAreNeverSlimmed() {
        let slimmable = slimmableSet()
        let managed = managedSet()
        let desired = Profile().desired()
        for service in categories.flatMap(\.alwaysEnabled) {
            #expect(!slimmable.contains(service.label))
            #expect(!desired.contains(service.label))
            #expect(managed.contains(service.label))
            #expect(!service.reason.isEmpty)
        }
    }

    @Test("categories contain impact metadata")
    func categoriesHaveImpactMetadata() {
        for category in categories {
            #expect(!category.downside.isEmpty)
            #expect(category.approxMemoryMB > 0)
        }
    }

    @Test("category lookup resolves only known identifiers")
    func categoryLookup() {
        for category in categories {
            #expect(categoryByID(category.id)?.id == category.id)
        }
        #expect(categoryByID("nope") == nil)
    }

    @Test(
        "delta computes sorted, allowlisted transitions",
        arguments: [
            DeltaCase(
                current: [],
                desired: ["a", "b", "c"],
                expectedDisable: ["a", "b", "c"],
                expectedEnable: []
            ),
            DeltaCase(
                current: ["a", "b", "c"],
                desired: [],
                expectedDisable: [],
                expectedEnable: ["a", "b", "c"]
            ),
            DeltaCase(
                current: ["a", "b"],
                desired: ["a", "b"],
                expectedDisable: [],
                expectedEnable: []
            ),
            DeltaCase(
                current: ["a", "b"],
                desired: ["b", "c"],
                expectedDisable: ["c"],
                expectedEnable: ["a"]
            ),
            DeltaCase(
                current: [],
                desired: ["x"],
                expectedDisable: [],
                expectedEnable: []
            ),
            DeltaCase(
                current: ["x"],
                desired: [],
                expectedDisable: [],
                expectedEnable: []
            ),
        ]
    )
    func profileDelta(testCase: DeltaCase) {
        let result = delta(
            current: testCase.current,
            desired: testCase.desired,
            managed: ["a", "b", "c"]
        )
        #expect(result.toDisable == testCase.expectedDisable)
        #expect(result.toEnable == testCase.expectedEnable)
    }

    @Test("category JSON omits an empty always-enabled list")
    func categoryJSONOmission() throws {
        let search = try #require(categoryByID("search"))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(search)) as? [String: Any]
        )
        #expect(object["approxMemoryMB"] as? Int == 50)
        #expect(object["alwaysEnabled"] == nil)
    }
}

struct DeltaCase: CustomTestStringConvertible, Sendable {
    let current: Set<String>
    let desired: Set<String>
    let expectedDisable: [String]
    let expectedEnable: [String]

    var testDescription: String {
        "\(current.sorted()) -> \(desired.sorted())"
    }
}
