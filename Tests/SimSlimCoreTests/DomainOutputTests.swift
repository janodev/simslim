import Foundation
import SimSlimCore
import Testing

@Suite("Machine-readable domain output")
struct DomainOutputTests {
    @Test("empty top output preserves Go's null slice representation")
    func emptyTopOutputUsesNullSims() throws {
        let data = try JSONEncoder().encode(TopOutput(sims: [], totalBytes: 0))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sims"] is NSNull)
        #expect(object["totalBytes"] as? Int == 0)
    }

    private let device = Device(
        udid: "DEVICE-1",
        name: "iPhone 17 Pro",
        state: "Booted",
        osVersion: "27.0",
        set: "testing",
        dataPath: "/private/ignored"
    )

    @Test("dropped categories retain catalog order and sort labels")
    func droppedCategoryGrouping() throws {
        let search = try #require(categoryByID("search"))
        let result = droppedCategories(disabled: [
            search.labels[1],
            search.labels[0],
            "com.apple.assistantd",
            "com.apple.not-a-managed-d",
        ])
        #expect(result.map(\.id) == ["siri", "search"])
        #expect(result[0].labels == ["com.apple.assistantd"])
        #expect(result[1].labels == [search.labels[0], search.labels[1]].sorted())
        #expect(result.allSatisfy { !$0.downside.isEmpty })
        #expect(droppedCategories(disabled: []).isEmpty)
    }

    @Test("device summary flattens device fields and omits empty optionals")
    func deviceSummaryJSON() throws {
        let summary = DeviceSummary(device: device, managedTotal: 170)
        let object = try jsonObject(summary)
        #expect(object["udid"] as? String == "DEVICE-1")
        #expect(object["osVersion"] as? String == "27.0")
        #expect(object["set"] as? String == "testing")
        #expect(object["managedTotal"] as? Int == 170)
        #expect(object["dataPath"] == nil)
        #expect(object["managedDisabled"] == nil)
        #expect(object["statusError"] == nil)
        #expect(object["memory"] == nil)
        #expect(object["memoryError"] == nil)
    }

    @Test("status output flattens status and omits empty dropped categories")
    func statusOutputJSON() throws {
        let output = StatusOutput(
            status: Status(managedDisabled: 12, managedTotal: 170, booted: true),
            verdict: "slim"
        )
        let object = try jsonObject(output)
        #expect(object["managedDisabled"] as? Int == 12)
        #expect(object["managedTotal"] as? Int == 170)
        #expect(object["booted"] as? Bool == true)
        #expect(object["verdict"] as? String == "slim")
        #expect(object["dropped"] == nil)
    }

    @Test("doctor JSON applies Go omitempty semantics")
    func doctorOutputJSON() throws {
        let output = DoctorOutput(
            ok: true,
            features: [
                FeatureStatus(id: "push", name: "Push notifications", ok: true),
            ]
        )
        let object = try jsonObject(output)
        #expect(object["udid"] == nil)
        let encodedFeatures = try #require(object["features"] as? [[String: Any]])
        #expect(encodedFeatures[0]["disabled"] == nil)
    }

    @Test("top simulator output flattens its device and retains measurements")
    func topSimJSON() throws {
        let top = TopSim(
            device: device,
            managedDisabled: 160,
            managedTotal: 170,
            memory: Measurement(processes: 65, bytes: 595_765_248, cpu: 2.5),
            diskBytes: 1_024
        )
        let object = try jsonObject(top)
        #expect(object["name"] as? String == "iPhone 17 Pro")
        #expect(object["managedDisabled"] as? Int == 160)
        #expect(object["diskBytes"] as? Int == 1_024)
        #expect(object["dataPath"] == nil)
        let memory = try #require(object["memory"] as? [String: Any])
        #expect(memory["processes"] as? Int == 65)
    }

    @Test("per-process output omits an empty device name")
    func topProcessesJSON() throws {
        let output = TopProcesses(
            udid: "DEVICE-1",
            processes: [Process(pid: 42, command: "launchd_sim", bytes: 256, cpu: 1)],
            totalBytes: 256
        )
        let object = try jsonObject(output)
        #expect(object["name"] == nil)
        #expect(object["totalBytes"] as? Int == 256)
    }

    @Test("verification JSON omits empty drift lists")
    func verificationJSON() throws {
        let object = try jsonObject(VerifyResult(udid: "DEVICE-1", ok: true))
        #expect(object["udid"] as? String == "DEVICE-1")
        #expect(object["ok"] as? Bool == true)
        #expect(object["missing"] == nil)
        #expect(object["extra"] == nil)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
