import Foundation

/// The JSON profile accepted by `simslim on --profile <path>`.
///
/// `except` and `keep` mirror the corresponding CLI flags. Empty values are
/// omitted when encoding, matching Go's `omitempty` contract.
public struct SlimProfile: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var except: [String]
    public var keep: [String]

    public init(
        name: String = "",
        description: String = "",
        except: [String] = [],
        keep: [String] = []
    ) {
        self.name = name
        self.description = description
        self.except = except
        self.keep = keep
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case except
        case keep
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        except = try container.decodeIfPresent([String].self, forKey: .except) ?? []
        keep = try container.decodeIfPresent([String].self, forKey: .keep) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !name.isEmpty {
            try container.encode(name, forKey: .name)
        }
        if !description.isEmpty {
            try container.encode(description, forKey: .description)
        }
        if !except.isEmpty {
            try container.encode(except, forKey: .except)
        }
        if !keep.isEmpty {
            try container.encode(keep, forKey: .keep)
        }
    }

    /// Resolves this file representation into a validated runtime profile.
    public func resolve(path: String) throws -> Profile {
        var resolved = Profile()
        for rawID in except {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard categoryByID(id) != nil else {
                throw SimSlimDomainError(
                    "profile \(path): unknown category \"\(id)\" (see `simslim profiles`)"
                )
            }
            resolved.exceptCategories.insert(id)
        }

        let slimmable = slimmableSet()
        for rawLabel in keep {
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            guard slimmable.contains(label) else {
                throw SimSlimDomainError(
                    "profile \(path): \"\(label)\" is not a daemon any category disables "
                        + "(see `simslim profiles`)"
                )
            }
            resolved.keep.insert(label)
        }
        return resolved
    }
}

/// Loads and strictly decodes a profile file. Unknown JSON fields are rejected
/// so a typo cannot silently change the selected service set.
public func loadSlimProfile(at path: String) throws -> Profile {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw SimSlimDomainError("read profile \(path): \(error.localizedDescription)")
    }

    do {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw SimSlimDomainError("profile must contain a JSON object")
        }
        let allowedKeys: Set<String> = ["name", "description", "except", "keep"]
        if let unknownKey = Set(dictionary.keys).subtracting(allowedKeys).sorted().first {
            throw SimSlimDomainError("unknown field \"\(unknownKey)\"")
        }
        let profile = try JSONDecoder().decode(SlimProfile.self, from: data)
        return try profile.resolve(path: path)
    } catch let error as SimSlimDomainError {
        throw SimSlimDomainError("parse profile \(path): \(error.description)")
    } catch {
        throw SimSlimDomainError("parse profile \(path): \(error.localizedDescription)")
    }
}

/// Parses the comma-separated syntax shared by `--except`, `--keep`,
/// `--requires`, and `--categories`, dropping blank entries.
public func splitList(_ value: String) -> [String] {
    value
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Selects a profile for an `on` invocation. A profile file is the single
/// source of truth and cannot be combined with `--except` or `--keep`.
public func buildProfile(
    profilePath: String,
    except: String,
    keep: String
) throws -> Profile {
    if !profilePath.isEmpty {
        guard except.isEmpty, keep.isEmpty else {
            throw SimSlimDomainError("--profile cannot be combined with --except or --keep")
        }
        return try loadSlimProfile(at: profilePath)
    }

    var profile = Profile()
    for id in splitList(except) {
        guard categoryByID(id) != nil else {
            throw SimSlimDomainError(
                "unknown category \"\(id)\" (see `simslim profiles`)"
            )
        }
        profile.exceptCategories.insert(id)
    }
    profile.keep.formUnion(splitList(keep))
    return profile
}

/// Encodes an on-disk profile as deterministic indented JSON ending in a
/// newline.
public func marshalProfile(_ profile: SlimProfile) throws -> Data {
    // JSONEncoder pretty-prints an empty keyed container as "{\n\n}", while
    // Go's json.MarshalIndent emits the canonical compact empty object "{}".
    // Preserve the established byte-level form used by generated profiles.
    if profile == SlimProfile() {
        return Data("{}\n".utf8)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(profile)
    data.append(0x0A)
    return data
}

/// Derives a safe JSON filename from a profile name.
public func profileFileName(_ name: String) -> String {
    let normalized = name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    var slug = ""
    var previousWasDash = false

    for scalar in normalized.unicodeScalars {
        let value = scalar.value
        let allowed = (97...122).contains(value)
            || (48...57).contains(value)
            || scalar == "_"
            || scalar == "."
        if allowed {
            slug.unicodeScalars.append(scalar)
            previousWasDash = false
        } else if !previousWasDash {
            slug.append("-")
            previousWasDash = true
        }
    }

    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    guard !slug.isEmpty else { return "profile.json" }
    return slug.hasSuffix(".json") ? slug : "\(slug).json"
}
