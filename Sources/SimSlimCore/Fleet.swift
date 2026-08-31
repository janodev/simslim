import Foundation

public struct FleetService: Sendable {
    public let simctl: SimCtl
    public let measurement: MeasurementService
    public let slimming: SlimmingService
    public let diskSize: DiskSizeService

    public init(
        simctl: SimCtl = SimCtl(),
        measurement: MeasurementService? = nil,
        slimming: SlimmingService? = nil,
        diskSize: DiskSizeService? = nil
    ) {
        self.simctl = simctl
        self.measurement = measurement ?? MeasurementService(runner: simctl.runner)
        self.slimming = slimming ?? SlimmingService(simctl: simctl)
        self.diskSize = diskSize ?? DiskSizeService(simctl: simctl)
    }

    /// Gathers status and an optional disk measurement for every booted
    /// simulator, sharing one host process/memory snapshot across the fleet.
    public func snapshot(withDisk: Bool) async throws -> TopOutput {
        let booted = try await simctl.listDevices().filter { $0.state == "Booted" }
        let memoryResult = try await measurement.measureMany(udids: booted.map(\.udid))

        let liveResults = try await withThrowingTaskGroup(of: FleetLiveResult.self) { group in
            for (index, device) in booted.enumerated() {
                group.addTask {
                    let status: Status?
                    let statusError: String
                    do {
                        status = try await slimming.readStatus(for: device).status
                        statusError = ""
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        status = nil
                        statusError = Self.describe(error)
                    }

                    let diskBytes: Int64?
                    if withDisk {
                        do {
                            diskBytes = try await diskSize.deviceDiskUsage(udid: device.udid).bytes
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            diskBytes = nil
                        }
                    } else {
                        diskBytes = nil
                    }
                    return FleetLiveResult(
                        index: index,
                        device: device,
                        status: status,
                        statusError: statusError,
                        diskBytes: diskBytes
                    )
                }
            }

            var results: [FleetLiveResult] = []
            results.reserveCapacity(booted.count)
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }

        var totalBytes: Int64 = 0
        var sims: [TopSim] = []
        sims.reserveCapacity(liveResults.count)
        for live in liveResults {
            let memory = memoryResult.measurements[live.device.udid]
            if let memory {
                totalBytes += memory.bytes
            }
            sims.append(
                TopSim(
                    device: live.device,
                    managedDisabled: live.status?.managedDisabled,
                    managedTotal: live.status?.managedTotal ?? 0,
                    statusError: live.statusError,
                    memory: memory,
                    memoryError: memoryResult.errors[live.device.udid] ?? "",
                    diskBytes: live.diskBytes
                )
            )
        }
        sims.sort { Self.topBytes($0) > Self.topBytes($1) }
        return TopOutput(sims: sims, totalBytes: totalBytes)
    }

    public static func topBytes(_ sim: TopSim) -> Int64 {
        sim.memory?.bytes ?? -1
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private struct FleetLiveResult: Sendable {
    let index: Int
    let device: Device
    let status: Status?
    let statusError: String
    let diskBytes: Int64?
}
