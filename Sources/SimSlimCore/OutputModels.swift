/// A category containing managed services that are currently disabled.
public struct DroppedCategory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let downside: String
    public let labels: [String]

    public init(id: String, name: String, downside: String, labels: [String]) {
        self.id = id
        self.name = name
        self.downside = downside
        self.labels = labels
    }
}

/// Groups disabled managed services in catalog category order, with each
/// category's labels sorted for deterministic output.
public func droppedCategories(disabled: Set<String>) -> [DroppedCategory] {
    categories.compactMap { category in
        let labels = category.labels.filter(disabled.contains).sorted()
        guard !labels.isEmpty else { return nil }
        return DroppedCategory(
            id: category.id,
            name: category.name,
            downside: category.downside,
            labels: labels
        )
    }
}

/// Machine-readable result of a simulator-management command.
public struct SimulatorMutationOutput: Codable, Equatable, Sendable {
    public let action: String
    public let udid: String
    public let name: String
    public let sourceUdid: String

    public init(
        action: String,
        udid: String,
        name: String = "",
        sourceUdid: String = ""
    ) {
        self.action = action
        self.udid = udid
        self.name = name
        self.sourceUdid = sourceUdid
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case udid
        case name
        case sourceUdid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(udid, forKey: .udid)
        if !name.isEmpty {
            try container.encode(name, forKey: .name)
        }
        if !sourceUdid.isEmpty {
            try container.encode(sourceUdid, forKey: .sourceUdid)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        udid = try container.decode(String.self, forKey: .udid)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sourceUdid = try container.decodeIfPresent(String.self, forKey: .sourceUdid) ?? ""
    }
}

/// One required feature and the services it needs that are currently down.
public struct FeatureStatus: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let ok: Bool
    public let disabled: [String]

    public init(id: String, name: String, ok: Bool, disabled: [String] = []) {
        self.id = id
        self.name = name
        self.ok = ok
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case ok
        case disabled
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(ok, forKey: .ok)
        if !disabled.isEmpty {
            try container.encode(disabled, forKey: .disabled)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ok = try container.decode(Bool.self, forKey: .ok)
        disabled = try container.decodeIfPresent([String].self, forKey: .disabled) ?? []
    }
}

/// Whether every requested feature survives the current slimming profile.
public struct DoctorOutput: Codable, Equatable, Sendable {
    public var udid: String
    public let ok: Bool
    public let features: [FeatureStatus]

    public init(
        udid: String = "",
        ok: Bool,
        features: [FeatureStatus]
    ) {
        self.udid = udid
        self.ok = ok
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case udid
        case ok
        case features
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !udid.isEmpty {
            try container.encode(udid, forKey: .udid)
        }
        try container.encode(ok, forKey: .ok)
        try container.encode(features, forKey: .features)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decodeIfPresent(String.self, forKey: .udid) ?? ""
        ok = try container.decode(Bool.self, forKey: .ok)
        features = try container.decode([FeatureStatus].self, forKey: .features)
    }
}

public struct DiskMeasurement: Codable, Equatable, Sendable {
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }
}

/// Stable machine-readable device state used by the macOS app and other
/// integrations. Device fields are flattened to match Go's embedded struct.
public struct DeviceSummary: Codable, Equatable, Sendable {
    public let device: Device
    public let managedDisabled: Int?
    public let managedTotal: Int
    public let statusError: String
    public let memory: Measurement?
    public let memoryError: String

    public init(
        device: Device,
        managedDisabled: Int? = nil,
        managedTotal: Int,
        statusError: String = "",
        memory: Measurement? = nil,
        memoryError: String = ""
    ) {
        self.device = device
        self.managedDisabled = managedDisabled
        self.managedTotal = managedTotal
        self.statusError = statusError
        self.memory = memory
        self.memoryError = memoryError
    }

    public var udid: String { device.udid }
    public var name: String { device.name }
    public var state: String { device.state }
    public var osVersion: String { device.osVersion }
    public var set: String { device.set }

    private enum CodingKeys: String, CodingKey {
        case udid
        case name
        case state
        case osVersion
        case set
        case managedDisabled
        case managedTotal
        case statusError
        case memory
        case memoryError
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(device.udid, forKey: .udid)
        try container.encode(device.name, forKey: .name)
        try container.encode(device.state, forKey: .state)
        try container.encode(device.osVersion, forKey: .osVersion)
        try container.encode(device.set, forKey: .set)
        try container.encodeIfPresent(managedDisabled, forKey: .managedDisabled)
        try container.encode(managedTotal, forKey: .managedTotal)
        if !statusError.isEmpty {
            try container.encode(statusError, forKey: .statusError)
        }
        try container.encodeIfPresent(memory, forKey: .memory)
        if !memoryError.isEmpty {
            try container.encode(memoryError, forKey: .memoryError)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try Device(
            udid: container.decode(String.self, forKey: .udid),
            name: container.decode(String.self, forKey: .name),
            state: container.decode(String.self, forKey: .state),
            osVersion: container.decode(String.self, forKey: .osVersion),
            set: container.decode(String.self, forKey: .set)
        )
        managedDisabled = try container.decodeIfPresent(Int.self, forKey: .managedDisabled)
        managedTotal = try container.decode(Int.self, forKey: .managedTotal)
        statusError = try container.decodeIfPresent(String.self, forKey: .statusError) ?? ""
        memory = try container.decodeIfPresent(Measurement.self, forKey: .memory)
        memoryError = try container.decodeIfPresent(String.self, forKey: .memoryError) ?? ""
    }
}

/// Status plus its user-facing verdict and optional dropped-category detail.
/// Status fields are flattened to match Go's embedded struct.
public struct StatusOutput: Codable, Equatable, Sendable {
    public let status: Status
    public let verdict: String
    public let dropped: [DroppedCategory]

    public init(
        status: Status,
        verdict: String,
        dropped: [DroppedCategory] = []
    ) {
        self.status = status
        self.verdict = verdict
        self.dropped = dropped
    }

    public var managedDisabled: Int { status.managedDisabled }
    public var managedTotal: Int { status.managedTotal }
    public var booted: Bool { status.booted }

    private enum CodingKeys: String, CodingKey {
        case managedDisabled
        case managedTotal
        case booted
        case verdict
        case dropped
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.managedDisabled, forKey: .managedDisabled)
        try container.encode(status.managedTotal, forKey: .managedTotal)
        try container.encode(status.booted, forKey: .booted)
        try container.encode(verdict, forKey: .verdict)
        if !dropped.isEmpty {
            try container.encode(dropped, forKey: .dropped)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try Status(
            managedDisabled: container.decode(Int.self, forKey: .managedDisabled),
            managedTotal: container.decode(Int.self, forKey: .managedTotal),
            booted: container.decode(Bool.self, forKey: .booted)
        )
        verdict = try container.decode(String.self, forKey: .verdict)
        dropped = try container.decodeIfPresent([DroppedCategory].self, forKey: .dropped) ?? []
    }
}

/// One booted simulator's live resource snapshot. Device fields are flattened
/// in JSON to preserve the existing machine-readable contract.
public struct TopSim: Codable, Equatable, Sendable {
    public let device: Device
    public let managedDisabled: Int?
    public let managedTotal: Int
    public let statusError: String
    public let memory: Measurement?
    public let memoryError: String
    public let diskBytes: Int64?

    public init(
        device: Device,
        managedDisabled: Int? = nil,
        managedTotal: Int,
        statusError: String = "",
        memory: Measurement? = nil,
        memoryError: String = "",
        diskBytes: Int64? = nil
    ) {
        self.device = device
        self.managedDisabled = managedDisabled
        self.managedTotal = managedTotal
        self.statusError = statusError
        self.memory = memory
        self.memoryError = memoryError
        self.diskBytes = diskBytes
    }

    public var udid: String { device.udid }
    public var name: String { device.name }
    public var state: String { device.state }
    public var osVersion: String { device.osVersion }
    public var set: String { device.set }

    private enum CodingKeys: String, CodingKey {
        case udid
        case name
        case state
        case osVersion
        case set
        case managedDisabled
        case managedTotal
        case statusError
        case memory
        case memoryError
        case diskBytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(device.udid, forKey: .udid)
        try container.encode(device.name, forKey: .name)
        try container.encode(device.state, forKey: .state)
        try container.encode(device.osVersion, forKey: .osVersion)
        try container.encode(device.set, forKey: .set)
        try container.encodeIfPresent(managedDisabled, forKey: .managedDisabled)
        try container.encode(managedTotal, forKey: .managedTotal)
        if !statusError.isEmpty {
            try container.encode(statusError, forKey: .statusError)
        }
        try container.encodeIfPresent(memory, forKey: .memory)
        if !memoryError.isEmpty {
            try container.encode(memoryError, forKey: .memoryError)
        }
        try container.encodeIfPresent(diskBytes, forKey: .diskBytes)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try Device(
            udid: container.decode(String.self, forKey: .udid),
            name: container.decode(String.self, forKey: .name),
            state: container.decode(String.self, forKey: .state),
            osVersion: container.decode(String.self, forKey: .osVersion),
            set: container.decode(String.self, forKey: .set)
        )
        managedDisabled = try container.decodeIfPresent(Int.self, forKey: .managedDisabled)
        managedTotal = try container.decode(Int.self, forKey: .managedTotal)
        statusError = try container.decodeIfPresent(String.self, forKey: .statusError) ?? ""
        memory = try container.decodeIfPresent(Measurement.self, forKey: .memory)
        memoryError = try container.decodeIfPresent(String.self, forKey: .memoryError) ?? ""
        diskBytes = try container.decodeIfPresent(Int64.self, forKey: .diskBytes)
    }
}

/// Fleet resource view for all booted simulators.
public struct TopOutput: Codable, Equatable, Sendable {
    public let sims: [TopSim]
    public let totalBytes: Int64

    public init(sims: [TopSim], totalBytes: Int64) {
        self.sims = sims
        self.totalBytes = totalBytes
    }

    private enum CodingKeys: String, CodingKey {
        case sims
        case totalBytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if sims.isEmpty {
            try container.encodeNil(forKey: .sims)
        } else {
            try container.encode(sims, forKey: .sims)
        }
        try container.encode(totalBytes, forKey: .totalBytes)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sims = try container.decodeIfPresent([TopSim].self, forKey: .sims) ?? []
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
    }
}

/// One simulator's per-process resource breakdown.
public struct TopProcesses: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let processes: [Process]
    public let totalBytes: Int64

    public init(
        udid: String,
        name: String = "",
        processes: [Process],
        totalBytes: Int64
    ) {
        self.udid = udid
        self.name = name
        self.processes = processes
        self.totalBytes = totalBytes
    }

    private enum CodingKeys: String, CodingKey {
        case udid
        case name
        case processes
        case totalBytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(udid, forKey: .udid)
        if !name.isEmpty {
            try container.encode(name, forKey: .name)
        }
        try container.encode(processes, forKey: .processes)
        try container.encode(totalBytes, forKey: .totalBytes)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        processes = try container.decode([Process].self, forKey: .processes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
    }
}
