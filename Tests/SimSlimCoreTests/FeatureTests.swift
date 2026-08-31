import SimSlimCore
import Testing

@Suite("Feature diagnosis")
struct FeatureTests {
    @Test("feature labels are all slimmable")
    func featureLabelsAreSlimmable() {
        let slimmable = slimmableSet()
        for feature in features {
            #expect(!feature.labels.isEmpty)
            for label in feature.labels {
                #expect(slimmable.contains(label))
            }
        }
    }

    @Test("feature identifiers are unique and named")
    func featureIDsAreUniqueAndNamed() {
        #expect(Set(features.map(\.id)).count == features.count)
        for feature in features {
            #expect(!feature.id.isEmpty)
            #expect(!feature.name.isEmpty)
        }
    }

    @Test("feature resolution preserves request order")
    func resolveFeaturesInOrder() throws {
        let resolved = try resolveFeatures(["push", "storekit"])
        #expect(resolved.map(\.id) == ["push", "storekit"])
    }

    @Test("feature resolution rejects unknown IDs")
    func rejectUnknownFeature() {
        #expect(throws: SimSlimDomainError.self) {
            try resolveFeatures(["push", "nope"])
        }
    }

    @Test("all features are healthy on a stock device")
    func stockDeviceDiagnosis() throws {
        let resolved = try resolveFeatures(["push", "storekit", "universal-links"])
        let report = diagnoseFeatures(resolved, disabled: [])
        #expect(report.ok)
        #expect(report.features.allSatisfy { $0.ok })
    }

    @Test("a disabled daemon breaks only its dependent features")
    func disabledDaemonDiagnosis() throws {
        let resolved = try resolveFeatures(["push", "storekit", "universal-links"])
        let report = diagnoseFeatures(resolved, disabled: ["com.apple.storekitd"])
        let byID = Dictionary(uniqueKeysWithValues: report.features.map { ($0.id, $0) })

        #expect(!report.ok)
        #expect(byID["storekit"]?.ok == false)
        #expect(byID["storekit"]?.disabled == ["com.apple.storekitd"])
        #expect(byID["push"]?.ok == true)
        #expect(byID["universal-links"]?.ok == true)
    }

    @Test("any disabled backing daemon breaks a multi-daemon feature")
    func multiDaemonFeature() throws {
        let spotlight = try resolveFeatures(["spotlight"])
        let report = diagnoseFeatures(
            spotlight,
            disabled: ["com.apple.searchtoold"]
        )
        #expect(!report.ok)
    }
}
