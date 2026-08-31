import ArgumentParser
import Darwin
import Foundation
import SimSlimCore

struct ProfilesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Show service categories controlled by a slim profile."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "An optional category ID.") var categoryID: String?

    func run() throws {
        _ = try parent.globals.resolve()
        if let categoryID {
            guard let category = categoryByID(categoryID) else {
                throw ValidationError("unknown category \"\(categoryID)\" (see `simslim profiles`)")
            }
            if json {
                try writeJSON(category)
            } else {
                printCategory(category)
            }
            return
        }

        if json {
            try writeJSON(categories)
            return
        }
        for category in categories {
            print(padded(category.id, width: 14) + " " + category.name)
            print("               \(category.labels.count) daemons · ~\(category.approxMemoryMB) MB idle footprint when enabled")
            print("               When disabled: \(category.downside)")
            for service in category.alwaysEnabled {
                print("               Always on: \(service.label) — \(service.reason)")
            }
        }
        print("\n\(slimmableSet().count) daemons across \(categories.count) categories. Core workflow and deadlock-prone daemons are never disabled.")
        print("Memory estimates are iOS 26.5 clean-boot measurements; they vary by runtime and workload and are not additive.")
    }

    private func printCategory(_ category: SimSlimCore.Category) {
        print(padded(category.id, width: 14) + " " + category.name)
        print("               \(category.description)")
        print("               \(category.labels.count) daemons · ~\(category.approxMemoryMB) MB idle footprint when enabled")
        print("               When disabled: \(category.downside)")
        print("\nDaemons:")
        for label in category.labels {
            if let description = category.serviceDescriptions[label], !description.isEmpty {
                print("  " + padded(label, width: 44) + " " + description)
            } else {
                print("  \(label)")
            }
        }
        for service in category.alwaysEnabled {
            print("  " + padded(service.label, width: 44) + " Always on — " + service.reason)
        }
    }
}

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Interactively build a JSON service profile."
    )

    @ParentCommand var parent: SimSlimCommand
    @Argument(help: "Output file or existing directory; omit for stdout.") var destination: String?

    func run() throws {
        _ = try parent.globals.resolve()
        guard isTerminal(STDIN_FILENO) else {
            throw ValidationError("profile is interactive; run it in a terminal")
        }

        var isDirectory: ObjCBool = false
        var writeIntoDirectory = false
        if let destination,
           FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory)
        {
            guard isDirectory.boolValue else {
                throw ValidationError("refusing to overwrite \(destination)")
            }
            writeIntoDirectory = true
        }

        let profile: SlimProfile
        do {
            profile = try buildProfileInteractively()
        } catch ProfileWizardError.cancelled {
            writeStandardError("Cancelled; no profile written.\n")
            return
        }
        let data = try marshalProfile(profile)
        writeStandardError(
            "Keeping \(profile.except.count) feature(s) fully enabled and "
                + "\(profile.keep.count) individual daemon(s); slimming the rest.\n"
        )

        guard var path = destination else {
            try FileHandle.standardOutput.write(contentsOf: data)
            return
        }
        if writeIntoDirectory {
            path = URL(fileURLWithPath: path, isDirectory: true)
                .appending(path: profileFileName(profile.name))
                .path
            if FileManager.default.fileExists(atPath: path) {
                try FileHandle.standardOutput.write(contentsOf: data)
                throw ValidationError("\(path) already exists; printed the profile above instead of overwriting it")
            }
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        } catch {
            throw ValidationError("write \(path): \(error.localizedDescription)")
        }
        writeStandardError("Wrote \(path). Apply it with `simslim on <udid> --profile \(path)`.\n")
    }
}

func padded(_ value: String, width: Int) -> String {
    guard value.count < width else { return value }
    return value + String(repeating: " ", count: width - value.count)
}

func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data(value.utf8))
}
