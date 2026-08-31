import Foundation

func truncated(_ value: String, to maximumLength: Int) -> String {
    guard value.count > maximumLength else { return value }
    guard maximumLength > 1 else { return "…" }
    return String(value.prefix(maximumLength - 1)) + "…"
}

func humanBytes(_ bytes: Int64) -> String {
    switch bytes {
    case (1 << 30)...:
        return String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    case (1 << 20)...:
        return String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
    case (1 << 10)...:
        return String(format: "%.0f KB", Double(bytes) / Double(1 << 10))
    default:
        return "\(bytes) B"
    }
}

func compactBytes(_ bytes: Int64) -> String {
    let unit: Int64 = 1_024
    guard bytes >= unit else { return "\(bytes)B" }

    let suffixes = Array("KMGTPE")
    var divisor = unit
    var exponent = 0
    var quotient = bytes / unit
    while quotient >= unit, exponent < suffixes.count - 1 {
        divisor *= unit
        quotient /= unit
        exponent += 1
    }
    return String(format: "%.1f%@", Double(bytes) / Double(divisor), String(suffixes[exponent]))
}

func shortUDID(_ udid: String) -> String {
    String(udid.prefix(8))
}

func versionIsLess(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
    let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
    for index in 0 ..< min(left.count, right.count) {
        let leftPart = String(left[index])
        let rightPart = String(right[index])
        if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
            if leftNumber != rightNumber { return leftNumber < rightNumber }
        } else if leftPart != rightPart {
            return leftPart < rightPart
        }
    }
    return left.count < right.count
}
