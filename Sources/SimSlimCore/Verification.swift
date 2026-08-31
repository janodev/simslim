/// How a simulator's launchd disable overrides compare with a profile's
/// desired set. Only labels in SimSlim's managed universe are considered.
public struct VerifyResult: Codable, Equatable, Sendable {
    public var udid: String
    public var ok: Bool
    /// Labels the profile wants disabled that are currently enabled.
    public var missing: [String]
    /// Managed labels disabled beyond what the profile requests.
    public var extra: [String]

    public init(
        udid: String = "",
        ok: Bool = false,
        missing: [String] = [],
        extra: [String] = []
    ) {
        self.udid = udid
        self.ok = ok
        self.missing = missing
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case udid
        case ok
        case missing
        case extra
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        ok = try container.decode(Bool.self, forKey: .ok)
        missing = try container.decodeIfPresent([String].self, forKey: .missing) ?? []
        extra = try container.decodeIfPresent([String].self, forKey: .extra) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(udid, forKey: .udid)
        try container.encode(ok, forKey: .ok)
        if !missing.isEmpty {
            try container.encode(missing, forKey: .missing)
        }
        if !extra.isEmpty {
            try container.encode(extra, forKey: .extra)
        }
    }
}

/// Diffs currently disabled labels against the desired profile, ignoring
/// unmanaged labels in both directions.
public func compareDisabled(
    disabled: Set<String>,
    desired: Set<String>,
    managed: Set<String>
) -> VerifyResult {
    let missing = desired.subtracting(disabled).sorted()
    let extra = disabled
        .intersection(managed)
        .subtracting(desired)
        .sorted()
    return VerifyResult(
        ok: missing.isEmpty && extra.isEmpty,
        missing: missing,
        extra: extra
    )
}

/// Checks, without mutating anything, that a booted simulator's launchd
/// overrides exactly match a profile. This detects profile state lost after a
/// device is erased or recreated.
public func verifyProfile(
    udid: String,
    profile: Profile,
    simctl: SimCtl = SimCtl()
) async throws -> VerifyResult {
    let device = try await simctl.findDevice(udid: udid)
    guard device.state == "Booted" else {
        throw SlimmingError.simulatorMustBeBooted(state: device.state)
    }
    let disabled = try await simctl.readDisabled(set: device.set, udid: device.udid)
    var result = compareDisabled(
        disabled: disabled,
        desired: profile.desired(),
        managed: managedSet()
    )
    result.udid = udid
    return result
}
