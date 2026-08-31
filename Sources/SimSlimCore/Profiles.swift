/// A launchd service that SimSlim never disables, but may need to re-enable
/// when repairing state written by an older release.
public struct AlwaysEnabledService: Codable, Equatable, Sendable {
    public let label: String
    public let reason: String

    public init(label: String, reason: String) {
        self.label = label
        self.reason = reason
    }
}

/// A user-facing group of launchd services that a slim profile controls
/// together.
public struct Category: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let downside: String
    public let approxMemoryMB: Int
    public let labels: [String]
    public let serviceDescriptions: [String: String]
    public let alwaysEnabled: [AlwaysEnabledService]

    public init(
        id: String,
        name: String,
        description: String,
        downside: String,
        approxMemoryMB: Int,
        labels: [String],
        serviceDescriptions: [String: String],
        alwaysEnabled: [AlwaysEnabledService] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.downside = downside
        self.approxMemoryMB = approxMemoryMB
        self.labels = labels
        self.serviceDescriptions = serviceDescriptions
        self.alwaysEnabled = alwaysEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case downside
        case approxMemoryMB
        case labels
        case serviceDescriptions
        case alwaysEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        downside = try container.decode(String.self, forKey: .downside)
        approxMemoryMB = try container.decode(Int.self, forKey: .approxMemoryMB)
        labels = try container.decode([String].self, forKey: .labels)
        serviceDescriptions = try container.decode([String: String].self, forKey: .serviceDescriptions)
        alwaysEnabled = try container.decodeIfPresent([AlwaysEnabledService].self, forKey: .alwaysEnabled) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(downside, forKey: .downside)
        try container.encode(approxMemoryMB, forKey: .approxMemoryMB)
        try container.encode(labels, forKey: .labels)
        try container.encode(serviceDescriptions, forKey: .serviceDescriptions)
        if !alwaysEnabled.isEmpty {
            try container.encode(alwaysEnabled, forKey: .alwaysEnabled)
        }
    }
}

private func makeCategory(
    id: String,
    name: String,
    description: String,
    downside: String,
    approxMemoryMB: Int,
    labels: [String],
    alwaysEnabled: [AlwaysEnabledService] = []
) -> Category {
    let descriptions = Dictionary(uniqueKeysWithValues: labels.map { label in
        guard let description = serviceDescriptionByLabel[label] else {
            preconditionFailure("Missing service description for \(label)")
        }
        return (label, description)
    })
    return Category(
        id: id,
        name: name,
        description: description,
        downside: downside,
        approxMemoryMB: approxMemoryMB,
        labels: labels,
        serviceDescriptions: descriptions,
        alwaysEnabled: alwaysEnabled
    )
}

/// The complete allowlist of launchd services that a profile may disable.
///
/// Categories can overlap. If any owning category is excepted, the shared
/// service remains enabled. Memory estimates are rounded medians measured on
/// an iOS 26.5 clean boot; they vary by runtime and workload and are not
/// additive.
public let categories: [Category] = [
    makeCategory(
        id: "widgets",
        name: "Widgets & Wallpaper",
        description: "Home and lock screen posters, widgets, and Live Activities.",
        downside: "Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating.",
        approxMemoryMB: 675,
        labels: [
            "com.apple.PosterBoard",
            "com.apple.chronod",
            "com.apple.liveactivitiesd",
        ]
    ),
    makeCategory(
        id: "siri",
        name: "Siri & Intelligence",
        description: "Siri, Apple Intelligence, speech, and on-device ML model services.",
        downside: "Siri, speech features, and Apple Intelligence services are unavailable.",
        approxMemoryMB: 265,
        labels: [
            "com.apple.assistantd",
            "com.apple.assistant_cdmd",
            "com.apple.assistant_service",
            "com.apple.siriactionsd",
            "com.apple.siriinferenced",
            "com.apple.siriknowledged",
            "com.apple.sirittsd",
            "com.apple.siri.context.service",
            "com.apple.siri.acousticsignature",
            "com.apple.corespeechd",
            "com.apple.voiced",
            "com.apple.voicebankingd",
            "com.apple.speechmodeltrainingd",
            "com.apple.intelligenceplatformd",
            "com.apple.intelligencecontextd",
            "com.apple.intelligenceflowd",
            "com.apple.intelligencetasksd",
            "com.apple.generativeexperiencesd",
            "com.apple.knowledgeconstructiond",
            "com.apple.naturallanguaged",
            "com.apple.textunderstandingd",
            "com.apple.modelcatalogd",
            "com.apple.modelmanagerd",
            "com.apple.mlhostd",
            "com.apple.mlruntimed",
            "com.apple.suggestd",
            "com.apple.parsecd",
            "com.apple.parsec-fbf",
            "com.apple.proactiveeventtrackerd",
        ]
    ),
    makeCategory(
        id: "search",
        name: "Spotlight & Search",
        description: "On-device Spotlight and in-Settings search services.",
        downside: "Spotlight and Settings search return no results.",
        approxMemoryMB: 50,
        labels: [
            "com.apple.searchd",
            "com.apple.searchtoold",
            "com.apple.spotlightknowledged",
            "com.apple.spotlightknowledged.updater",
            "com.apple.corespotlightservice",
        ]
    ),
    makeCategory(
        id: "icloud",
        name: "iCloud & Apple Account",
        description: "iCloud sync, Apple Account, keychain, and backup services.",
        downside: "iCloud sync, Apple Account, Keychain, and backup workflows will not work.",
        approxMemoryMB: 100,
        labels: [
            "com.apple.appleaccountd",
            "com.apple.appleaccounttransparencyd",
            "com.apple.appleidsetupd",
            "com.apple.akd",
            "com.apple.amsaccountsd",
            "com.apple.amsengagementd",
            "com.apple.amsondevicestoraged",
            "com.apple.cloudd",
            "com.apple.cloudphotod",
            "com.apple.ckdiscretionaryd",
            "com.apple.cloudsettingssyncagent",
            "com.apple.bird",
            "com.apple.syncdefaultsd",
            "com.apple.cdpd",
            "com.apple.sosd",
            "com.apple.SecureBackupDaemon",
            "com.apple.TrustedPeersHelper",
            "com.apple.protectedcloudstorage.protectedcloudkeysyncing",
            "com.apple.icloudmailagent",
            "com.apple.icloudsubscriptionoptimizerd",
            "com.apple.communicationtrustd",
        ]
    ),
    makeCategory(
        id: "store",
        name: "App Store, Push & Media",
        description: "App Store, push notification, StoreKit, and media services.",
        downside: "Remote push notifications and StoreKit or App Store testing will not work.",
        approxMemoryMB: 80,
        labels: [
            "com.apple.appstored",
            "com.apple.appstorecomponentsd",
            "com.apple.apsd",
            "com.apple.itunescloudd",
            "com.apple.itunesstored",
            "com.apple.storekitd",
            // Shared with iCloud because Apple Media Services renders the
            // in-app purchase payment sheet.
            "com.apple.amsaccountsd",
            "com.apple.amsengagementd",
            "com.apple.amsondevicestoraged",
            // Wallet hosts the payment authorization sheet and depends on the
            // Finance datastore. Both are also in `other`.
            "com.apple.passd",
            "com.apple.financed",
            "com.apple.videosubscriptionsd",
            "com.apple.assetsubscriptiond",
            "com.apple.musicd",
        ]
    ),
    makeCategory(
        id: "pim",
        name: "Mail, Calendar & Contacts",
        description: "Mail, Calendar, Contacts, Reminders, and related sync services.",
        downside: "Contacts, Calendar, Reminders, and Mail-backed pickers or sync may fail.",
        approxMemoryMB: 80,
        labels: [
            "com.apple.email.maild",
            "com.apple.exchangesyncd",
            "com.apple.dataaccess.dataaccessd",
            "com.apple.calaccessd",
            "com.apple.remindd",
            "com.apple.contactsd",
            "com.apple.contacts.postersyncd",
            "com.apple.peopled",
        ]
    ),
    makeCategory(
        id: "web",
        name: "Safari Sync & Web Services",
        description: "Safari sync, web push, privacy, and universal-link services.",
        downside: "Universal links and Safari sync or background web services will not work.",
        approxMemoryMB: 50,
        labels: [
            "com.apple.SafariBookmarksSyncAgent",
            "com.apple.Safari.History",
            "com.apple.Safari.passwordbreachd",
            "com.apple.Safari.SafeBrowsing.Service",
            "com.apple.safarifetcherd",
            "com.apple.WebBookmarks.webbookmarksd",
            "com.apple.webkit.adattributiond",
            "com.apple.webkit.webpushd",
            "com.apple.webprivacyd",
            "com.apple.swcd",
        ]
    ),
    makeCategory(
        id: "family",
        name: "Family & Screen Time",
        description: "Family Sharing, Screen Time, and usage tracking.",
        downside: "Family Sharing, Screen Time, and usage tracking stop working.",
        approxMemoryMB: 65,
        labels: [
            "com.apple.familycircled",
            "com.apple.FamilyControlsAgent",
            "com.apple.familynotification",
            "com.apple.askpermissiond",
            "com.apple.asktod",
            "com.apple.ScreenTimeAgent",
            "com.apple.ScreenTimeSettingsAgent",
            "com.apple.UsageTrackingAgent",
        ]
    ),
    makeCategory(
        id: "health",
        name: "Health, Home & Fitness",
        description: "HealthKit, HomeKit, and Fitness services.",
        downside: "HealthKit, HomeKit, and Fitness integrations will not work.",
        approxMemoryMB: 135,
        labels: [
            "com.apple.healthd",
            "com.apple.healthappd",
            "com.apple.healthcontentd",
            "com.apple.healtheventsd",
            "com.apple.healthrecordsd",
            "com.apple.finhealthd",
            "com.apple.homed",
            "com.apple.homeeventsd",
            "com.apple.fitcore",
            "com.apple.fitcore.session",
            "com.apple.fitnesscoachingd",
            "com.apple.fitnessintelligenced",
            "com.apple.activityawardsd",
            "com.apple.activitysharingd",
        ]
    ),
    makeCategory(
        id: "photos",
        name: "Photos & Media Analysis",
        description: "Photos library, photo analysis, and media analysis services.",
        downside: "Photo picker, Photos-library workflows, and media analysis may fail.",
        approxMemoryMB: 60,
        labels: [
            "com.apple.photoanalysisd",
            "com.apple.photosface",
            "com.apple.mediaanalysisd",
            "com.apple.mediaanalysisd.service",
            "com.apple.mediastream.mstreamd",
            "com.apple.medialibraryd",
            "com.apple.assetsd",
            "com.apple.assetsd.nebulad",
        ]
    ),
    makeCategory(
        id: "apps",
        name: "News, Weather, Maps & Games",
        description: "News, Weather, Maps, Tips, and game services.",
        downside: "News, Weather, Maps background data, and game-controller services are unavailable.",
        approxMemoryMB: 90,
        labels: [
            "com.apple.newsd",
            "com.apple.weatherd",
            "com.apple.Maps.mapssyncd",
            "com.apple.Maps.mapspushd",
            "com.apple.Maps.geocorrectiond",
            "com.apple.maps.destinationd",
            "com.apple.MapKit.SnapshotService",
            "com.apple.jetpackassetd",
            "com.apple.tipsd",
            "com.apple.gamed",
            "com.apple.gamesaved",
            "com.apple.GameController.gamecontrollerd",
        ]
    ),
    makeCategory(
        id: "messaging",
        name: "Messaging & FaceTime",
        description: "iMessage, FaceTime, call, and identity services.",
        downside: "iMessage, FaceTime, and related identity services will not work.",
        approxMemoryMB: 60,
        labels: [
            "com.apple.identityservicesd",
            "com.apple.ids_simd",
            "com.apple.imautomatichistorydeletionagent",
            "com.apple.imcore.imtransferagent",
            "com.apple.imdpersistence.IMDPersistenceAgent",
            "com.apple.facetimemessagestored",
            "com.apple.telephonyutilities.callservicesd",
        ]
    ),
    makeCategory(
        id: "connectivity",
        name: "Sharing & Device Connectivity",
        description: "AirDrop, Continuity, CarPlay, Watch, and Find My services.",
        downside: "AirDrop, Continuity, CarPlay, Watch, and Find My connectivity will not work.",
        approxMemoryMB: 65,
        labels: [
            "com.apple.rapportd",
            "com.apple.companiond",
            "com.apple.carkitd",
            "com.apple.wcd",
            "com.apple.tvremoted",
            "com.apple.avatarsd",
            "com.apple.stickersd",
            "com.apple.sociallayerd",
            "com.apple.announced",
            "com.apple.navd",
            "com.apple.findmy.findmylocated",
        ],
        alwaysEnabled: [
            AlwaysEnabledService(
                label: "com.apple.sharingd",
                reason: "Required for system share sheets."
            ),
        ]
    ),
    makeCategory(
        id: "telemetry",
        name: "Ads, Diagnostics & Telemetry",
        description: "DeviceCheck, ad privacy, analytics, diagnostics, and feedback services.",
        downside: "DeviceCheck plus analytics, diagnostics, and feedback services are unavailable.",
        approxMemoryMB: 105,
        labels: [
            "com.apple.ap.adprivacyd",
            "com.apple.ap.promotedcontentd",
            "com.apple.diagnosticextensionsd",
            "com.apple.feedbackd",
            "com.apple.rtcreportingd",
            "com.apple.securityuploadd",
            "com.apple.geoanalyticsd",
            "com.apple.triald",
            "com.apple.followupd",
            "com.apple.purplebuddy.budd",
            "com.apple.devicecheckd",
        ]
    ),
    makeCategory(
        id: "other",
        name: "Other Background Services",
        description: "Wallet, business services, assets, and miscellaneous background daemons.",
        downside: "Wallet, merchant, business, asset, and miscellaneous background services are unavailable.",
        approxMemoryMB: 195,
        labels: [
            "com.apple.financed",
            "com.apple.passd",
            "com.apple.merchantd",
            "com.apple.coreidvd",
            "com.apple.businessservicesd",
            "com.apple.deviceaccessd",
            "com.apple.replicatord",
            "com.apple.linkd",
            "com.apple.ind",
            "com.apple.storagedatad",
            "com.apple.StatusKitAgent",
            "com.apple.countryd",
            "com.apple.mobileassetd",
            "com.apple.managedconfiguration.passcodenagd",
        ]
    ),
]

public func categoryByID(_ id: String) -> Category? {
    categories.first { $0.id == id }
}

/// Every label a service profile is allowed to disable.
public func slimmableSet() -> Set<String> {
    Set(categories.flatMap(\.labels))
}

/// The complete mutation allowlist. Most labels are slimmable; required
/// labels may only transition back to enabled for compatibility.
public func managedSet() -> Set<String> {
    var result = slimmableSet()
    result.formUnion(categories.flatMap(\.alwaysEnabled).map(\.label))
    return result
}

/// Selects which managed services a slim boot should disable.
public struct Profile: Equatable, Sendable {
    public var exceptCategories: Set<String>
    public var keep: Set<String>

    public init(
        exceptCategories: Set<String> = [],
        keep: Set<String> = []
    ) {
        self.exceptCategories = exceptCategories
        self.keep = keep
    }

    /// The labels this profile wants disabled. If categories share a label,
    /// excepting any one of them keeps that label enabled.
    public func desired() -> Set<String> {
        var result = slimmableSet()
        for category in categories where exceptCategories.contains(category.id) {
            result.subtract(category.labels)
        }
        result.subtract(keep)
        return result
    }
}

/// Calculates the deterministic launchctl transitions needed to reach a
/// profile, without ever touching labels outside the managed allowlist.
public func delta(
    current: Set<String>,
    desired: Set<String>,
    managed: Set<String>
) -> (toDisable: [String], toEnable: [String]) {
    let toDisable = desired
        .intersection(managed)
        .subtracting(current)
        .sorted()
    let toEnable = current
        .intersection(managed)
        .subtracting(desired)
        .sorted()
    return (toDisable, toEnable)
}
