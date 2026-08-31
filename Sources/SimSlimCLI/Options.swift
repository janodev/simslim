import ArgumentParser
import Foundation
import SimSlimCore

struct ResolvedGlobalOptions: Sendable {
    let bootTimeout: Duration
    let deviceSets: [String]
    let spawnTimeout: Duration
}

struct GlobalOptions: ParsableArguments, Sendable {
    @Option(
        name: .long,
        help: "Also scan these device sets (comma-separated name or path)."
    )
    var set: String?

    @Option(
        name: .long,
        help: "Maximum time to boot and reconfigure a simulator, such as 10m or 15m."
    )
    var bootTimeout: String?

    @Option(
        name: .long,
        help: "Maximum time for one launchctl transition, such as 2m or 5m."
    )
    var spawnTimeout: String?

    func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ResolvedGlobalOptions {
        let deviceSets: [String]
        if let set {
            deviceSets = splitList(set)
            guard !deviceSets.isEmpty else {
                throw ValidationError("--set requires a device set name (such as `testing`) or a path")
            }
        } else {
            deviceSets = []
        }

        return try ResolvedGlobalOptions(
            bootTimeout: resolvedBootTimeout(environment: environment),
            deviceSets: deviceSets,
            spawnTimeout: resolvedSpawnTimeout(environment: environment)
        )
    }

    func resolvedBootTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Duration {
        try resolvedDuration(
            explicit: bootTimeout,
            environment: environment["SIMSLIM_BOOT_TIMEOUT"],
            fallback: .seconds(600),
            option: "--boot-timeout"
        )
    }

    func resolvedSpawnTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Duration {
        try resolvedDuration(
            explicit: spawnTimeout,
            environment: environment["SIMSLIM_SPAWN_TIMEOUT"],
            fallback: .seconds(120),
            option: "--spawn-timeout"
        )
    }

    private func resolvedDuration(
        explicit: String?,
        environment: String?,
        fallback: Duration,
        option: String
    ) throws -> Duration {
        guard let value = explicit ?? environment else { return fallback }
        guard let duration = parseDuration(value), duration > .zero else {
            throw ValidationError("\(option) must be a positive duration")
        }
        return duration
    }
}

func parseDuration(_ value: String) -> Duration? {
    guard !value.isEmpty else { return nil }

    var index = value.startIndex
    var isNegative = false
    if value[index] == "+" || value[index] == "-" {
        if value[index] == "-" {
            isNegative = true
        }
        index = value.index(after: index)
        guard index < value.endIndex else { return nil }
    }
    if value[index...] == "0" {
        return .zero
    }

    let units: [(String, UInt64)] = [
        ("ns", 1),
        ("us", 1_000),
        ("µs", 1_000),
        ("μs", 1_000),
        ("ms", 1_000_000),
        ("s", 1_000_000_000),
        ("m", 60_000_000_000),
        ("h", 3_600_000_000_000),
    ]
    var totalNanoseconds: UInt64 = 0
    var parsedComponent = false
    while index < value.endIndex {
        var integer: UInt64 = 0
        var sawIntegerDigit = false
        while index < value.endIndex, let digit = value[index].wholeNumberValue {
            sawIntegerDigit = true
            let (scaled, multiplyOverflow) = integer.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = scaled.addingReportingOverflow(UInt64(digit))
            guard !multiplyOverflow, !addOverflow else { return nil }
            integer = next
            index = value.index(after: index)
        }

        var fraction: UInt64 = 0
        var fractionScale: UInt64 = 1
        var sawFractionDigit = false
        if index < value.endIndex, value[index] == "." {
            index = value.index(after: index)
            while index < value.endIndex, let digit = value[index].wholeNumberValue {
                sawFractionDigit = true
                if fractionScale < 1_000_000_000_000_000_000 {
                    fraction = fraction * 10 + UInt64(digit)
                    fractionScale *= 10
                }
                index = value.index(after: index)
            }
        }
        guard sawIntegerDigit || sawFractionDigit else { return nil }
        guard let unit = units.first(where: { value[index...].hasPrefix($0.0) }) else { return nil }
        index = value.index(index, offsetBy: unit.0.count)

        let (integralNanoseconds, multiplyOverflow) = integer.multipliedReportingOverflow(by: unit.1)
        guard !multiplyOverflow else { return nil }
        let fractionalProduct = fraction.multipliedFullWidth(by: unit.1)
        let fractionalNanoseconds = fractionScale.dividingFullWidth(fractionalProduct).quotient
        let (component, componentOverflow) = integralNanoseconds.addingReportingOverflow(fractionalNanoseconds)
        let (nextTotal, totalOverflow) = totalNanoseconds.addingReportingOverflow(component)
        guard !componentOverflow, !totalOverflow else { return nil }
        totalNanoseconds = nextTotal
        parsedComponent = true
    }

    guard parsedComponent else { return nil }
    let negativeLimit = UInt64(Int64.max) + 1
    if isNegative {
        guard totalNanoseconds <= negativeLimit else { return nil }
        if totalNanoseconds == negativeLimit {
            return .nanoseconds(Int64.min)
        }
        return .nanoseconds(-Int64(totalNanoseconds))
    }
    guard totalNanoseconds <= UInt64(Int64.max) else { return nil }
    return .nanoseconds(Int64(totalNanoseconds))
}
