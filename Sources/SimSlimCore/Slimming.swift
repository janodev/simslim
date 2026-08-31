import Foundation

public typealias Reporter = @Sendable (String) -> Void

public struct Status: Codable, Equatable, Sendable {
    public let managedDisabled: Int
    public let managedTotal: Int
    public let booted: Bool

    public init(managedDisabled: Int, managedTotal: Int, booted: Bool) {
        self.managedDisabled = managedDisabled
        self.managedTotal = managedTotal
        self.booted = booted
    }
}

public enum SlimmingError: Error, Equatable, LocalizedError, Sendable {
    case simulatorMustBeBooted(state: String)
    case persistenceLost(lost: Int, applied: Int, osVersion: String?)
    case reconfigureTimedOut(Duration)

    public var errorDescription: String? {
        switch self {
        case .simulatorMustBeBooted(let state):
            return "simulator must be booted to read its state (it is \(state))"
        case .persistenceLost(let lost, let applied, let osVersion):
            var message = "the disable overrides did not survive the reboot "
                + "(\(lost) of \(applied) changes lost)"
            if let osVersion {
                message += "; iOS \(osVersion) runtimes do not persist launchd overrides "
                    + "— use an iOS 18 or newer runtime"
            }
            return message
        case .reconfigureTimedOut(let timeout):
            return "simulator reconfiguration timed out after \(timeout)"
        }
    }
}

public struct SlimmingService: Sendable {
    public let simctl: SimCtl

    public init(simctl: SimCtl = SimCtl()) {
        self.simctl = simctl
    }

    /// Brings a simulator to exactly the desired managed disabled state.
    /// Returns whether any launchd override changed.
    @discardableResult
    public func ensure(
        set: String,
        udid: String,
        desired: Set<String>,
        reporter: Reporter? = nil
    ) async throws -> Bool {
        let timeout = simctl.configuration.bootTimeout
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await ensureWithinBudget(
                    set: set,
                    udid: udid,
                    desired: desired,
                    reporter: reporter
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SlimmingError.reconfigureTimedOut(timeout)
            }

            guard let changed = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return changed
        }
    }

    private func ensureWithinBudget(
        set: String,
        udid: String,
        desired: Set<String>,
        reporter: Reporter?
    ) async throws -> Bool {
        reporter?("Booting the simulator (a first boot can take up to a minute)...")
        try await simctl.bootAndWait(set: set, udid: udid)

        let current = try await simctl.readDisabled(set: set, udid: udid)
        let transition = delta(current: current, desired: desired, managed: managedSet())
        guard !transition.toDisable.isEmpty || !transition.toEnable.isEmpty else {
            return false
        }

        if !transition.toDisable.isEmpty {
            reporter?("Disabling \(transition.toDisable.count) background services...")
        }
        if !transition.toEnable.isEmpty {
            reporter?("Re-enabling \(transition.toEnable.count) background services...")
        }

        try await simctl.applyDelta(
            set: set,
            udid: udid,
            toDisable: transition.toDisable,
            toEnable: transition.toEnable,
            reporter: reporter
        )

        reporter?("Rebooting the simulator to apply the changes...")
        do {
            try await simctl.shutdown(set: set, udid: udid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SlimmingOperationError(context: "shutdown before reboot", underlying: error)
        }
        try await simctl.waitShutdown(
            set: set,
            udid: udid,
            timeout: simctl.configuration.shutdownTimeout
        )
        try await simctl.bootAndWait(set: set, udid: udid)

        let after = try await simctl.readDisabled(set: set, udid: udid)
        let lost = Self.countLost(after: after, desired: desired, managed: managedSet())
        if lost > 0 {
            let device = try? await simctl.findDevice(udid: udid)
            let oldRuntime = device.flatMap { device -> String? in
                let major = Self.osMajor(device.osVersion)
                return major > 0 && major < 18 ? device.osVersion : nil
            }
            throw SlimmingError.persistenceLost(
                lost: lost,
                applied: transition.toDisable.count + transition.toEnable.count,
                osVersion: oldRuntime
            )
        }
        return true
    }

    @discardableResult
    public func enable(
        set: String,
        udid: String,
        profile: Profile,
        reporter: Reporter? = nil
    ) async throws -> Bool {
        try await ensure(
            set: set,
            udid: udid,
            desired: profile.desired(),
            reporter: reporter
        )
    }

    @discardableResult
    public func disable(
        set: String,
        udid: String,
        reporter: Reporter? = nil
    ) async throws -> Bool {
        try await ensure(set: set, udid: udid, desired: [], reporter: reporter)
    }

    public func readStatus(
        udid: String
    ) async throws -> (status: Status, disabled: Set<String>) {
        let device = try await simctl.findDevice(udid: udid)
        return try await readStatus(for: device)
    }

    public func readStatus(
        for device: Device
    ) async throws -> (status: Status, disabled: Set<String>) {
        let managed = slimmableSet()
        guard device.state == "Booted" else {
            throw SlimmingError.simulatorMustBeBooted(state: device.state)
        }
        let disabled = try await simctl.readDisabled(set: device.set, udid: device.udid)
        let status = Status(
            managedDisabled: disabled.intersection(managed).count,
            managedTotal: managed.count,
            booted: true
        )
        return (status, disabled)
    }

    public static func countLost(
        after: Set<String>,
        desired: Set<String>,
        managed: Set<String>
    ) -> Int {
        let transition = delta(current: after, desired: desired, managed: managed)
        return transition.toDisable.count + transition.toEnable.count
    }

    public static func osMajor(_ version: String) -> Int {
        Int(version.split(separator: ".", maxSplits: 1).first ?? "") ?? 0
    }
}

public struct SlimmingOperationError: Error, LocalizedError, Sendable {
    public let context: String
    public let underlyingDescription: String

    public init(context: String, underlying: any Error) {
        self.context = context
        if let localized = underlying as? any LocalizedError,
           let description = localized.errorDescription {
            underlyingDescription = description
        } else {
            underlyingDescription = String(describing: underlying)
        }
    }

    public var errorDescription: String? {
        "\(context): \(underlyingDescription)"
    }
}
