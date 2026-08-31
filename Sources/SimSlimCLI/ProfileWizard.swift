import Foundation
import SimSlimCore

enum ProfileWizardError: Error, Equatable {
    case cancelled
    case inputEnded
}

private protocol WizardByteReading {
    mutating func readByte() throws -> UInt8?
}

private struct FileWizardReader: WizardByteReading {
    let handle: FileHandle

    mutating func readByte() throws -> UInt8? {
        guard let data = try handle.read(upToCount: 1), !data.isEmpty else {
            return nil
        }
        return data[data.startIndex]
    }
}

private struct DataWizardReader: WizardByteReading {
    let data: Data
    var index = 0

    mutating func readByte() -> UInt8? {
        guard index < data.count else { return nil }
        defer { index += 1 }
        return data[index]
    }
}

private enum WizardKey: Equatable {
    case cancel
    case down
    case enter
    case left
    case other
    case right
    case rune(UInt8)
    case space
    case up
}

func buildProfileInteractively() throws -> SlimProfile {
    var reader = FileWizardReader(handle: .standardInput)
    let output: (String) -> Void = { value in
        FileHandle.standardError.write(Data(value.utf8))
    }

    output("Create a slim profile.\n\n")
    output("Name (optional): ")
    let name = try readWizardLine(reader: &reader)
    output("Description (optional): ")
    let description = try readWizardLine(reader: &reader)

    let raw = try RawTerminal()
    output("\u{001B}[?1049h\u{001B}[?25l")
    defer {
        output("\u{001B}[?25h\u{001B}[?1049l")
        raw.restore()
    }

    return try selectProfile(
        reader: &reader,
        output: output,
        rows: terminalRows(),
        name: name,
        description: description
    )
}

func runProfileWizard(input: Data, terminalRows: Int = 24) throws -> SlimProfile {
    var reader = DataWizardReader(data: input)
    let name = try readWizardLine(reader: &reader)
    let description = try readWizardLine(reader: &reader)
    return try selectProfile(
        reader: &reader,
        output: { _ in },
        rows: terminalRows,
        name: name,
        description: description
    )
}

private func readWizardLine<Reader: WizardByteReading>(reader: inout Reader) throws -> String {
    var bytes: [UInt8] = []
    while let byte = try reader.readByte() {
        if byte == 0x0A { break }
        if byte != 0x0D { bytes.append(byte) }
    }
    return String(decoding: bytes, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func readWizardKey<Reader: WizardByteReading>(reader: inout Reader) throws -> WizardKey {
    guard let byte = try reader.readByte() else { return .cancel }
    switch byte {
    case 0x03:
        return .cancel
    case 0x0A, 0x0D:
        return .enter
    case 0x20:
        return .space
    case 0x1B:
        guard try reader.readByte() == 0x5B else { return .other }
        switch try reader.readByte() {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        default: return .other
        }
    default:
        return .rune(byte)
    }
}

private func selectProfile<Reader: WizardByteReading>(
    reader: inout Reader,
    output: (String) -> Void,
    rows: Int,
    name: String,
    description: String
) throws -> SlimProfile {
    var except: Set<String> = []
    var keep: Set<String> = []
    let header = [
        "Features to keep enabled — everything unchecked is slimmed.",
        "[x] whole feature kept · [~] some daemons kept",
    ]
    let footer = "↑/↓ move · space keep feature · → pick daemons · a all · n none · enter save · q cancel"
    let visible = viewportRows(terminalRows: rows, headerLines: header.count)
    var cursor = 0
    var top = 0

    while true {
        let renderedRows = categoryRows(except: except, keep: keep)
        top = windowTop(top: top, cursor: cursor, visible: visible, total: renderedRows.count)
        drawChecklist(
            output: output,
            header: header,
            rows: renderedRows,
            footer: footer,
            cursor: cursor,
            top: top,
            visible: visible
        )

        let key = try readWizardKey(reader: &reader)
        switch key {
        case .up, .rune(0x6B):
            cursor = clampCursor(cursor - 1, count: renderedRows.count)
        case .down, .rune(0x6A):
            cursor = clampCursor(cursor + 1, count: renderedRows.count)
        case .enter:
            let exceptIDs = categories.compactMap { except.contains($0.id) ? $0.id : nil }
            let keptLabels = categories.flatMap { category -> [String] in
                guard !except.contains(category.id) else { return [] }
                return category.labels.filter(keep.contains)
            }
            return SlimProfile(
                name: name,
                description: description,
                except: exceptIDs,
                keep: keptLabels
            )
        case .cancel, .rune(0x51), .rune(0x71):
            throw ProfileWizardError.cancelled
        case .space:
            toggleMember(&except, categories[cursor].id)
        case .right, .rune(0x6C):
            try selectDaemons(
                reader: &reader,
                output: output,
                category: categories[cursor],
                keep: &keep,
                terminalRows: rows
            )
        case .rune(0x41), .rune(0x61):
            except = Set(categories.map(\.id))
        case .rune(0x4E), .rune(0x6E):
            except.removeAll()
        default:
            break
        }
    }
}

private func selectDaemons<Reader: WizardByteReading>(
    reader: inout Reader,
    output: (String) -> Void,
    category: SimSlimCore.Category,
    keep: inout Set<String>,
    terminalRows: Int
) throws {
    let header = [
        "\(category.name) — keep individual daemons enabled.",
        "Unchecked daemons in this feature are slimmed.",
    ]
    let footer = "↑/↓ move · space keep daemon · a all · n none · ← back · q cancel"
    let visible = viewportRows(terminalRows: terminalRows, headerLines: header.count)
    var cursor = 0
    var top = 0

    while true {
        let renderedRows = daemonRows(category: category, keep: keep)
        top = windowTop(top: top, cursor: cursor, visible: visible, total: renderedRows.count)
        drawChecklist(
            output: output,
            header: header,
            rows: renderedRows,
            footer: footer,
            cursor: cursor,
            top: top,
            visible: visible
        )

        let key = try readWizardKey(reader: &reader)
        switch key {
        case .up, .rune(0x6B):
            cursor = clampCursor(cursor - 1, count: renderedRows.count)
        case .down, .rune(0x6A):
            cursor = clampCursor(cursor + 1, count: renderedRows.count)
        case .left, .enter, .rune(0x48), .rune(0x68), .rune(0x51), .rune(0x71):
            return
        case .cancel:
            throw ProfileWizardError.cancelled
        case .space:
            toggleMember(&keep, category.labels[cursor])
        case .rune(0x41), .rune(0x61):
            keep.formUnion(category.labels)
        case .rune(0x4E), .rune(0x6E):
            keep.subtract(category.labels)
        default:
            break
        }
    }
}

private func categoryRows(except: Set<String>, keep: Set<String>) -> [String] {
    categories.map { category in
        if except.contains(category.id) {
            return "[x] \(category.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(category.name)"
        }
        let keptCount = category.labels.count(where: keep.contains)
        let marker = keptCount == 0 ? "[ ]" : "[~]"
        let suffix = keptCount == 0 ? "" : "  (\(keptCount) kept)"
        return "\(marker) \(category.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(category.name)\(suffix)"
    }
}

private func daemonRows(category: SimSlimCore.Category, keep: Set<String>) -> [String] {
    category.labels.map { label in
        let marker = keep.contains(label) ? "[x]" : "[ ]"
        let description = category.serviceDescriptions[label] ?? ""
        let labelColumn = label.padding(toLength: 44, withPad: " ", startingAt: 0)
        return truncated("\(marker) \(labelColumn) \(description)", to: 76)
    }
}

private func drawChecklist(
    output: (String) -> Void,
    header: [String],
    rows: [String],
    footer: String,
    cursor: Int,
    top: Int,
    visible: Int
) {
    var frame = "\u{001B}[H\u{001B}[J"
    frame += header.joined(separator: "\r\n") + "\r\n"
    let end = min(top + visible, rows.count)
    for index in top ..< end {
        frame += (index == cursor ? "❯ " : "  ") + rows[index] + "\r\n"
    }
    var more = ""
    if top > 0 { more += " ↑more" }
    if end < rows.count { more += " ↓more" }
    frame += "\r\n\(footer)\(more)"
    output(frame)
}

private func viewportRows(terminalRows: Int, headerLines: Int) -> Int {
    max(3, terminalRows - headerLines - 2)
}

private func windowTop(top: Int, cursor: Int, visible: Int, total: Int) -> Int {
    guard total > visible else { return 0 }
    var result = top
    if cursor < result { result = cursor }
    if cursor >= result + visible { result = cursor - visible + 1 }
    return min(max(0, result), total - visible)
}

private func clampCursor(_ value: Int, count: Int) -> Int {
    min(max(0, value), max(0, count - 1))
}

private func toggleMember(_ set: inout Set<String>, _ member: String) {
    if set.contains(member) {
        set.remove(member)
    } else {
        set.insert(member)
    }
}
