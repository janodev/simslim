import ArgumentParser
import Darwin
import Foundation
import SimSlimCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available simulators and their slim status."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Flag(name: .long, help: "Only list booted simulators.") var booted = false

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        var devices = try await services.simctl.listDevices()
        if booted {
            devices.removeAll { $0.state != "Booted" }
        }
        devices.sort {
            if $0.osVersion != $1.osVersion {
                return $0.osVersion > $1.osVersion
            }
            return $0.name < $1.name
        }

        let managedTotal = slimmableSet().count
        let memoryResult = json
            ? try await services.measurement.measureMany(
                udids: devices.filter { $0.state == "Booted" }.map(\.udid)
            )
            : (measurements: [:], errors: [:])
        var summaries: [DeviceSummary] = []

        for device in devices {
            var tag = "shutdown"
            var managedDisabled: Int?
            var statusError = ""
            if device.state == "Booted" {
                tag = "booted"
                do {
                    let status = try await services.slimming.readStatus(for: device).status
                    managedDisabled = status.managedDisabled
                    tag = "booted · \(status.managedDisabled)/\(managedTotal) slim"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    statusError = error.localizedDescription
                }
            }

            summaries.append(
                DeviceSummary(
                    device: device,
                    managedDisabled: managedDisabled,
                    managedTotal: managedTotal,
                    statusError: statusError,
                    memory: memoryResult.measurements[device.udid],
                    memoryError: memoryResult.errors[device.udid] ?? ""
                )
            )
            if !json {
                var line = "\(device.udid)  "
                    + padded(truncated(device.name, to: 22), width: 22)
                    + " iOS " + padded(device.osVersion, width: 6)
                    + " \(tag)"
                if device.set != "default", !device.set.isEmpty {
                    line += "  (\(device.set))"
                }
                print(line)
            }
        }

        if json {
            try writeJSON(summaries)
        }
    }
}

struct TopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top",
        abstract: "Monitor simulator RAM, CPU, and process counts."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print one machine-readable snapshot.") var json = false
    @Argument(help: "Optional simulator UDID for per-process detail.") var udid: String?

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        if json {
            if let udid {
                try writeJSON(try await topProcesses(udid: udid, services: services))
            } else {
                try writeJSON(try await services.fleet.snapshot(withDisk: true))
            }
            return
        }

        if isTerminal(STDOUT_FILENO) {
            try await runTopTUI(initialUDID: udid, services: services)
            return
        }
        if let udid {
            print(staticProcesses(try await topProcesses(udid: udid, services: services)), terminator: "")
        } else {
            print(staticFleet(try await services.fleet.snapshot(withDisk: false)), terminator: "")
        }
    }
}

func topProcesses(udid: String, services: CLIServices) async throws -> TopProcesses {
    let processes = try await services.measurement.measureProcesses(udid: udid)
    let name = (try? await services.simctl.findDevice(udid: udid).name) ?? ""
    return TopProcesses(
        udid: udid,
        name: name,
        processes: processes,
        totalBytes: processes.reduce(into: 0) { $0 += $1.bytes }
    )
}

func staticFleet(_ output: TopOutput) -> String {
    let nameWidth = 30
    var result = "" + padded("SIMULATOR", width: nameWidth)
        + " " + padded("OS", width: 6)
        + " " + padded("STATE", width: 6)
        + "  PROC    CPU      RAM\n"
    for sim in output.sims {
        let name = truncated("\(sim.name) · \(shortUDID(sim.udid))", to: nameWidth)
        result += padded(name, width: nameWidth)
            + " " + padded(sim.osVersion, width: 6)
            + " " + padded(topStateLabel(sim), width: 6)
            + " " + leftPadded(sim.memory.map { String($0.processes) } ?? "-", width: 5)
            + " " + leftPadded(sim.memory.map { String(format: "%.0f%%", $0.cpu) } ?? "-", width: 6)
            + " " + leftPadded(sim.memory.map { compactBytes($0.bytes) } ?? "-", width: 8)
            + "\n"
    }
    result += "\(output.sims.count) booted · total \(compactBytes(output.totalBytes))\n"
    return result
}

func staticProcesses(_ output: TopProcesses) -> String {
    let title = output.name.isEmpty ? shortUDID(output.udid) : output.name
    var result = "\(title) — daemons by RAM\n"
    result += leftPadded("RAM", width: 8) + " " + leftPadded("CPU", width: 6) + "  COMMAND\n"
    for process in output.processes {
        result += leftPadded(compactBytes(process.bytes), width: 8)
            + " " + leftPadded(String(format: "%.1f%%", process.cpu), width: 6)
            + "  \(process.command)"
            + "\n"
    }
    return result
}

func topStateLabel(_ sim: TopSim) -> String {
    guard let disabled = sim.managedDisabled else { return "?" }
    if disabled == sim.managedTotal { return "slim" }
    if disabled > 0 { return "part" }
    return "stock"
}
