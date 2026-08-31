import Darwin
import Foundation
import SimSlimCore

private enum TopView {
    case drill
    case fleet
}

private enum TopSort: Character {
    case cpu = "c"
    case disk = "d"
    case name = "n"
    case os = "o"
    case processes = "p"
    case ram = "m"
    case state = "s"
}

enum TopKey: Equatable {
    case back
    case down
    case enter
    case quit
    case rune(Character)
    case up
}

private struct TopDisplayState {
    var cursor = 0
    var cursorUDID = ""
    var disk: [String: Int64] = [:]
    var error = ""
    var processes: [SimSlimCore.Process] = []
    var scroll = 0
    var selectedName = ""
    var selectedUDID = ""
    var sims: [TopSim] = []
    var sort: TopSort = .ram
    var sortDescending = true
    var totalBytes: Int64 = 0
    var view: TopView = .fleet

    mutating func applyFleet(_ output: TopOutput) {
        sims = output.sims
        totalBytes = output.totalBytes
        for sim in sims {
            if let diskBytes = sim.diskBytes {
                disk[sim.udid] = diskBytes
            }
        }
        applySort()
        reanchor()
    }

    mutating func applySort() {
        sims.sort { lhs, rhs in
            let ordered: Bool
            switch sort {
            case .cpu:
                ordered = (lhs.memory?.cpu ?? -1) < (rhs.memory?.cpu ?? -1)
            case .disk:
                ordered = disk[lhs.udid, default: -1] < disk[rhs.udid, default: -1]
            case .name:
                ordered = lhs.name < rhs.name
            case .os:
                ordered = versionIsLess(lhs.osVersion, rhs.osVersion)
            case .processes:
                ordered = (lhs.memory?.processes ?? -1) < (rhs.memory?.processes ?? -1)
            case .ram:
                ordered = (lhs.memory?.bytes ?? -1) < (rhs.memory?.bytes ?? -1)
            case .state:
                ordered = (lhs.managedDisabled ?? -1) < (rhs.managedDisabled ?? -1)
            }
            return sortDescending ? !ordered && !equivalent(lhs, rhs, sort: sort, disk: disk) : ordered
        }
        sortProcesses()
    }

    mutating func setSort(_ newSort: TopSort) {
        if sort == newSort {
            sortDescending.toggle()
        } else {
            sort = newSort
            sortDescending = true
        }
        applySort()
        reanchor()
    }

    mutating func sortProcesses() {
        processes.sort { lhs, rhs in
            let ordered: Bool
            switch sort {
            case .cpu:
                ordered = lhs.cpu < rhs.cpu
            case .name:
                ordered = lhs.command < rhs.command
            default:
                ordered = lhs.bytes < rhs.bytes
            }
            if sortDescending {
                return ordered ? false : !processesEquivalent(lhs, rhs, sort: sort)
            }
            return ordered
        }
    }

    mutating func reanchor() {
        if !cursorUDID.isEmpty,
           let index = sims.firstIndex(where: { $0.udid == cursorUDID })
        {
            cursor = index
            return
        }
        cursorUDID = ""
        cursor = min(cursor, max(0, sims.count - 1))
    }
}

private enum TopRefreshPayload: Sendable {
    case drill(TopProcesses)
    case failure(String)
    case fleet(TopOutput, withDisk: Bool)
}

private struct TopRefreshResponse: Sendable {
    let generation: Int
    let payload: TopRefreshPayload
}

private actor TopRefreshMailbox {
    private var responses: [TopRefreshResponse] = []

    func append(_ response: TopRefreshResponse) {
        responses.append(response)
    }

    func take() -> TopRefreshResponse? {
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
}

func runTopTUI(initialUDID: String?, services: CLIServices) async throws {
    guard isTerminal(STDIN_FILENO) else {
        throw SimSlimCLIError("top requires an interactive terminal unless --json is used")
    }

    var state = TopDisplayState()
    if let initialUDID {
        state.view = .drill
        state.selectedUDID = initialUDID
    }

    let terminal = try RawTerminal()
    writeStandardOutput("\u{001B}[?1049h\u{001B}[?25l")
    defer {
        writeStandardOutput("\u{001B}[?25h\u{001B}[?1049l")
        terminal.restore()
    }

    let clock = ContinuousClock()
    let mailbox = TopRefreshMailbox()
    var activeGeneration: Int?
    var generation = 0
    var input = TopInputReader(fileDescriptor: STDIN_FILENO)
    var nextRefresh = clock.now
    var nextDiskRefresh = clock.now
    var needsRender = true
    var refreshTask: Task<Void, Never>?

    do {
        while true {
            if let response = await mailbox.take(), response.generation == activeGeneration {
                refreshTask = nil
                activeGeneration = nil
                switch response.payload {
                case .drill(let output):
                    if state.view == .drill, output.udid == state.selectedUDID {
                        state.selectedName = output.name
                        state.processes = output.processes
                        state.sortProcesses()
                        state.scroll = min(state.scroll, max(0, state.processes.count - 1))
                        state.error = ""
                    }
                case .failure(let message):
                    state.error = message
                case .fleet(let output, let withDisk):
                    if state.view == .fleet {
                        state.applyFleet(output)
                        state.error = ""
                        if withDisk {
                            nextDiskRefresh = clock.now.advanced(by: .seconds(30))
                        }
                    }
                }
                nextRefresh = clock.now.advanced(by: .seconds(2))
                needsRender = true
            }

            if needsRender {
                writeStandardOutput(renderTop(state))
                needsRender = false
            }

            if refreshTask == nil, clock.now >= nextRefresh {
                generation += 1
                let requestedGeneration = generation
                activeGeneration = requestedGeneration
                if state.view == .fleet {
                    let withDisk = clock.now >= nextDiskRefresh
                    refreshTask = Task {
                        let payload: TopRefreshPayload
                        do {
                            payload = .fleet(
                                try await services.fleet.snapshot(withDisk: withDisk),
                                withDisk: withDisk
                            )
                        } catch {
                            payload = .failure(error.localizedDescription)
                        }
                        await mailbox.append(
                            TopRefreshResponse(generation: requestedGeneration, payload: payload)
                        )
                    }
                } else {
                    let udid = state.selectedUDID
                    refreshTask = Task {
                        let payload: TopRefreshPayload
                        do {
                            payload = .drill(try await topProcesses(udid: udid, services: services))
                        } catch {
                            payload = .failure(error.localizedDescription)
                        }
                        await mailbox.append(
                            TopRefreshResponse(generation: requestedGeneration, payload: payload)
                        )
                    }
                }
            }

            guard let key = input.readKey(timeoutMilliseconds: 0) else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            switch key {
            case .quit:
                refreshTask?.cancel()
                await refreshTask?.value
                return
            case .up:
                if state.view == .fleet, state.cursor > 0 {
                    state.cursor -= 1
                    state.cursorUDID = state.sims[state.cursor].udid
                } else if state.view == .drill, state.scroll > 0 {
                    state.scroll -= 1
                }
            case .down:
                if state.view == .fleet, state.cursor < state.sims.count - 1 {
                    state.cursor += 1
                    state.cursorUDID = state.sims[state.cursor].udid
                } else if state.view == .drill, state.scroll < state.processes.count - 1 {
                    state.scroll += 1
                }
            case .enter:
                if state.view == .fleet, state.cursor < state.sims.count {
                    let sim = state.sims[state.cursor]
                    state.view = .drill
                    state.selectedUDID = sim.udid
                    state.selectedName = sim.name
                    state.processes = []
                    state.scroll = 0
                    refreshTask?.cancel()
                    await refreshTask?.value
                    refreshTask = nil
                    activeGeneration = nil
                    nextRefresh = clock.now
                }
            case .back:
                if state.view == .drill {
                    state.view = .fleet
                    state.selectedUDID = ""
                    state.processes = []
                    refreshTask?.cancel()
                    await refreshTask?.value
                    refreshTask = nil
                    activeGeneration = nil
                    nextRefresh = clock.now
                }
            case .rune(let character):
                if let sort = TopSort(rawValue: character),
                   state.view == .fleet || sort == .ram || sort == .cpu || sort == .name
                {
                    state.setSort(sort)
                }
            }
            needsRender = true
        }
    } catch {
        refreshTask?.cancel()
        await refreshTask?.value
        throw error
    }
}

struct TopInputReader {
    let fileDescriptor: Int32
    private var pending: [UInt8] = []

    mutating func readKey(timeoutMilliseconds: Int32) -> TopKey? {
        guard let first = readByte(timeoutMilliseconds: timeoutMilliseconds) else { return nil }
        if first == 0x1B {
            guard let second = readByte(timeoutMilliseconds: 25) else { return .back }
            guard second == 0x5B else {
                pending.insert(second, at: 0)
                return .back
            }
            guard let third = readByte(timeoutMilliseconds: 25) else {
                pending.insert(second, at: 0)
                return .back
            }
            switch third {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .enter
            case 0x44: return .back
            default:
                pending.insert(contentsOf: [second, third], at: 0)
                return .back
            }
        }

        switch first {
        case 0x03, 0x51, 0x71:
            return .quit
        case 0x0A, 0x0D:
            return .enter
        case 0x48, 0x68:
            return .back
        case 0x4A, 0x6A:
            return .down
        case 0x4B, 0x6B:
            return .up
        case 0x4C, 0x6C:
            return .enter
        default:
            return String(bytes: [first], encoding: .utf8)?.first.map(TopKey.rune)
        }
    }

    private mutating func readByte(timeoutMilliseconds: Int32) -> UInt8? {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0,
              descriptor.revents & Int16(POLLIN) != 0
        else {
            return nil
        }
        var byte: UInt8 = 0
        guard Darwin.read(fileDescriptor, &byte, 1) == 1 else { return nil }
        return byte
    }
}

private func renderTop(_ state: TopDisplayState) -> String {
    if state.view == .drill {
        return renderDrill(state)
    }
    return renderFleet(state)
}

private func renderFleet(_ state: TopDisplayState) -> String {
    let width = min(60, max(16, terminalColumns() - 45))
    let visibleRows = max(1, terminalRows() - 4)
    let top = viewportTop(cursor: state.cursor, count: state.sims.count, rows: visibleRows)
    let end = min(state.sims.count, top + visibleRows)
    var output = "\u{001B}[H\u{001B}[J\u{001B}[1m"
    output += padded("SIMULATOR\(sortArrow(.name, state: state))", width: width)
        + " " + padded("OS\(sortArrow(.os, state: state))", width: 6)
        + " " + padded("STATE\(sortArrow(.state, state: state))", width: 6)
        + " " + leftPadded("PROC\(sortArrow(.processes, state: state))", width: 5)
        + " " + leftPadded("CPU\(sortArrow(.cpu, state: state))", width: 6)
        + " " + leftPadded("RAM\(sortArrow(.ram, state: state))", width: 8)
        + " " + leftPadded("DISK\(sortArrow(.disk, state: state))", width: 8)
        + "\u{001B}[0m\r\n"

    if state.sims.isEmpty {
        output += "\u{001B}[2mNo booted simulators. Boot one with `simslim boot <udid>`.\u{001B}[0m\r\n"
    } else {
        for index in top ..< end {
            let sim = state.sims[index]
            let row = padded(truncated("\(sim.name) · \(shortUDID(sim.udid))", to: width), width: width)
                + " " + padded(truncated(sim.osVersion.isEmpty ? "?" : sim.osVersion, to: 6), width: 6)
                + " " + padded(topStateLabel(sim), width: 6)
                + " " + leftPadded(sim.memory.map { String($0.processes) } ?? "—", width: 5)
                + " " + leftPadded(sim.memory.map { String(format: "%.0f%%", $0.cpu) } ?? "—", width: 6)
                + " " + leftPadded(sim.memory.map { compactBytes($0.bytes) } ?? (sim.memoryError.isEmpty ? "—" : "err"), width: 8)
                + " " + leftPadded(state.disk[sim.udid].map(compactBytes) ?? "…", width: 8)
            output += index == state.cursor ? "\u{001B}[7m\(row)\u{001B}[0m\r\n" : "\(row)\r\n"
        }
    }
    output += "\u{001B}[2m" + String(repeating: "─", count: width + 45) + "\r\n"
    output += "\(state.sims.count) booted · total \(compactBytes(state.totalBytes))"
        + " · ↑↓ select · ↵ open · sort n·o·s·p·c·m·d · q quit"
    if !state.error.isEmpty {
        output += "\r\nrefresh error: \(state.error)"
    }
    return output + "\u{001B}[0m"
}

private func renderDrill(_ state: TopDisplayState) -> String {
    let title = state.selectedName.isEmpty ? shortUDID(state.selectedUDID) : state.selectedName
    let rows = max(1, terminalRows() - 5)
    let start = min(max(0, state.scroll), max(0, state.processes.count - rows))
    let end = min(state.processes.count, start + rows)
    var output = "\u{001B}[H\u{001B}[J\u{001B}[1m\(title) — daemons by \(drillSortLabel(state.sort))\u{001B}[0m\r\n\r\n"
    if !state.error.isEmpty {
        return output + "\u{001B}[2m\(state.error)\r\n\r\nesc back · q quit\u{001B}[0m"
    }
    if state.processes.isEmpty {
        return output + "\u{001B}[2mmeasuring…\r\n\r\nesc back · q quit\u{001B}[0m"
    }
    output += "\u{001B}[1m" + leftPadded("RAM\(sortArrow(.ram, state: state))", width: 8)
        + " " + leftPadded("CPU\(sortArrow(.cpu, state: state))", width: 6)
        + "  COMMAND\(sortArrow(.name, state: state))\u{001B}[0m\r\n"
    for process in state.processes[start ..< end] {
        output += leftPadded(compactBytes(process.bytes), width: 8)
            + " " + leftPadded(String(format: "%.1f%%", process.cpu), width: 6)
            + "  \(process.command)\r\n"
    }
    output += "\u{001B}[2m\(start + 1)–\(end) of \(state.processes.count)"
        + " · ↑↓ scroll · sort m·c·n · esc back · q quit\u{001B}[0m"
    return output
}

private func sortArrow(_ sort: TopSort, state: TopDisplayState) -> String {
    guard state.sort == sort else { return "" }
    return state.sortDescending ? "▼" : "▲"
}

private func drillSortLabel(_ sort: TopSort) -> String {
    switch sort {
    case .cpu: "CPU"
    case .name: "command"
    default: "RAM"
    }
}

private func viewportTop(cursor: Int, count: Int, rows: Int) -> Int {
    guard count > rows else { return 0 }
    return min(max(0, cursor - rows + 1), count - rows)
}

private func equivalent(
    _ lhs: TopSim,
    _ rhs: TopSim,
    sort: TopSort,
    disk: [String: Int64]
) -> Bool {
    switch sort {
    case .cpu: lhs.memory?.cpu == rhs.memory?.cpu
    case .disk: disk[lhs.udid] == disk[rhs.udid]
    case .name: lhs.name == rhs.name
    case .os: lhs.osVersion == rhs.osVersion
    case .processes: lhs.memory?.processes == rhs.memory?.processes
    case .ram: lhs.memory?.bytes == rhs.memory?.bytes
    case .state: lhs.managedDisabled == rhs.managedDisabled
    }
}

private func processesEquivalent(
    _ lhs: SimSlimCore.Process,
    _ rhs: SimSlimCore.Process,
    sort: TopSort
) -> Bool {
    switch sort {
    case .cpu: lhs.cpu == rhs.cpu
    case .name: lhs.command == rhs.command
    default: lhs.bytes == rhs.bytes
    }
}

private func writeStandardOutput(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
}
