import Foundation

/// A stable, user-facing error raised while resolving profile and feature
/// input. Keeping the message as data preserves the Go CLI's actionable error
/// text without carrying non-Sendable underlying errors across tasks.
public struct SimSlimDomainError: Error, Equatable, LocalizedError, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A user-facing capability backed by specific launchd services.
public struct Feature: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let labels: [String]

    public init(id: String, name: String, labels: [String]) {
        self.id = id
        self.name = name
        self.labels = labels
    }
}

/// Common capabilities and the services that must remain enabled for them.
public let features: [Feature] = [
    Feature(id: "push", name: "Push notifications", labels: ["com.apple.apsd"]),
    Feature(
        id: "storekit",
        name: "StoreKit / in-app purchase",
        labels: [
            "com.apple.storekitd",
            "com.apple.itunesstored",
            "com.apple.amsaccountsd",
            "com.apple.amsengagementd",
            "com.apple.amsondevicestoraged",
            "com.apple.passd",
            "com.apple.financed",
        ]
    ),
    Feature(
        id: "app-store",
        name: "App Store",
        labels: ["com.apple.appstored", "com.apple.itunesstored"]
    ),
    Feature(
        id: "universal-links",
        name: "Universal links / associated domains",
        labels: ["com.apple.swcd"]
    ),
    Feature(
        id: "spotlight",
        name: "Spotlight & Settings search",
        labels: ["com.apple.searchd", "com.apple.searchtoold"]
    ),
    Feature(
        id: "siri",
        name: "Siri & speech",
        labels: ["com.apple.assistantd", "com.apple.corespeechd"]
    ),
    Feature(id: "icloud", name: "iCloud sync", labels: ["com.apple.cloudd"]),
    Feature(id: "keychain-sync", name: "iCloud Keychain", labels: ["com.apple.akd"]),
    Feature(id: "contacts", name: "Contacts", labels: ["com.apple.contactsd"]),
    Feature(id: "calendar", name: "Calendar", labels: ["com.apple.calaccessd"]),
    Feature(id: "reminders", name: "Reminders", labels: ["com.apple.remindd"]),
    Feature(id: "mail", name: "Mail", labels: ["com.apple.email.maild"]),
    Feature(
        id: "photos",
        name: "Photos library & analysis",
        labels: ["com.apple.assetsd", "com.apple.photoanalysisd"]
    ),
    Feature(id: "health", name: "HealthKit", labels: ["com.apple.healthd"]),
    Feature(id: "homekit", name: "HomeKit", labels: ["com.apple.homed"]),
    Feature(
        id: "imessage",
        name: "iMessage & FaceTime",
        labels: ["com.apple.identityservicesd"]
    ),
    Feature(
        id: "widgets",
        name: "Widgets & Live Activities",
        labels: ["com.apple.chronod", "com.apple.liveactivitiesd"]
    ),
    Feature(id: "wallet", name: "Wallet & passes", labels: ["com.apple.passd"]),
    Feature(
        id: "maps",
        name: "Maps background services",
        labels: ["com.apple.Maps.mapssyncd"]
    ),
    Feature(id: "weather", name: "Weather", labels: ["com.apple.weatherd"]),
    Feature(id: "news", name: "News", labels: ["com.apple.newsd"]),
    Feature(id: "game-center", name: "Game Center", labels: ["com.apple.gamed"]),
    Feature(
        id: "find-my",
        name: "Find My",
        labels: ["com.apple.findmy.findmylocated"]
    ),
    Feature(
        id: "screen-time",
        name: "Screen Time",
        labels: ["com.apple.ScreenTimeAgent"]
    ),
]

public func featureByID(_ id: String) -> Feature? {
    features.first { $0.id == id }
}

/// Resolves requested IDs in request order and fails on the first typo.
public func resolveFeatures(_ ids: [String]) throws -> [Feature] {
    try ids.map { id in
        guard let feature = featureByID(id) else {
            throw SimSlimDomainError(
                "unknown feature \"\(id)\" (see `simslim doctor --list`)"
            )
        }
        return feature
    }
}

/// Reports which required services are disabled for each feature.
public func diagnoseFeatures(
    _ requestedFeatures: [Feature],
    disabled: Set<String>
) -> DoctorOutput {
    let statuses = requestedFeatures.map { feature in
        let down = feature.labels.filter(disabled.contains)
        return FeatureStatus(
            id: feature.id,
            name: feature.name,
            ok: down.isEmpty,
            disabled: down
        )
    }
    return DoctorOutput(
        ok: statuses.allSatisfy(\.ok),
        features: statuses
    )
}
