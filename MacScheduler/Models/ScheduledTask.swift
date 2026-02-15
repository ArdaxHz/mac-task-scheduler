//
//  ScheduledTask.swift
//  MacScheduler
//
//  The core model representing a scheduled task.
//  All tasks are native launchd/cron tasks — no app-specific prefixes.
//

import Foundation

/// Where a launchd plist is installed.
enum TaskLocation: String, Codable, CaseIterable {
    case userAgent = "User Agent"
    case systemAgent = "System Agent"
    case systemDaemon = "System Daemon"

    var directory: String {
        switch self {
        case .userAgent:
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path
        case .systemAgent:
            return "/Library/LaunchAgents"
        case .systemDaemon:
            return "/Library/LaunchDaemons"
        }
    }

    var requiresElevation: Bool {
        self != .userAgent
    }

    var systemImage: String {
        switch self {
        case .userAgent: return "person"
        case .systemAgent: return "person.2"
        case .systemDaemon: return "gearshape.2"
        }
    }
}

enum SchedulerBackend: String, Codable, CaseIterable {
    case launchd = "launchd"
    case cron = "cron"

    var displayName: String {
        switch self {
        case .launchd: return "launchd (Recommended)"
        case .cron: return "cron"
        }
    }

    var description: String {
        switch self {
        case .launchd: return "Native macOS scheduler with more features"
        case .cron: return "Traditional Unix scheduler"
        }
    }
}

struct ScheduledTask: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var backend: SchedulerBackend
    var action: TaskAction
    var trigger: TaskTrigger
    var status: TaskStatus
    var createdAt: Date
    var modifiedAt: Date
    var runAtLoad: Bool
    var keepAlive: Bool
    var standardOutPath: String?
    var standardErrorPath: String?
    /// The native launchd label for this task (e.g. com.apple.example or com.user.mytask).
    var launchdLabel: String
    var isReadOnly: Bool
    /// Full path to the plist file on disk (set during discovery, nil for new tasks).
    var plistFilePath: String?
    /// Where this task's plist is installed (user agent, system agent, or system daemon).
    var location: TaskLocation
    /// For system daemons: the user to run as (UserName key in plist).
    var userName: String?

    init(id: UUID = UUID(),
         name: String = "",
         description: String = "",
         backend: SchedulerBackend = .launchd,
         action: TaskAction = TaskAction(),
         trigger: TaskTrigger = .onDemand,
         status: TaskStatus = TaskStatus(),
         createdAt: Date = Date(),
         modifiedAt: Date = Date(),
         runAtLoad: Bool = false,
         keepAlive: Bool = false,
         standardOutPath: String? = nil,
         standardErrorPath: String? = nil,
         launchdLabel: String = "",
         isReadOnly: Bool = false,
         plistFilePath: String? = nil,
         location: TaskLocation = .userAgent,
         userName: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.backend = backend
        self.action = action
        self.trigger = trigger
        self.status = status
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.launchdLabel = launchdLabel
        self.isReadOnly = isReadOnly
        self.plistFilePath = plistFilePath
        self.location = location
        self.userName = userName
    }

    var plistFileName: String {
        // Allowlist sanitization: only permit safe filename characters
        let sanitized = String(launchdLabel.unicodeScalars.map { scalar in
            if scalar.isASCII,
               scalar.value >= 0x20,
               "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars.contains(scalar) {
                return Character(scalar)
            }
            return Character("_")
        })
        return "\(sanitized).plist"
    }

    /// Generate a deterministic UUID from a launchd label string.
    static func uuidFromLabel(_ label: String) -> UUID {
        let data = Data(label.utf8)
        var uuidBytes = [UInt8](repeating: 0, count: 16)

        for round in 0..<16 {
            // Vary the seed per round so each byte is independently computed
            var hash: UInt64 = 5381 &+ UInt64(round) &* 2654435761
            for byte in data {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            uuidBytes[round] = UInt8(truncatingIfNeeded: hash >> 8)
        }

        return UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                          uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                          uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                          uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }

    /// Generate a launchd-style label from a task name.
    static func labelFromName(_ name: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            .joined()
        let label = sanitized.isEmpty ? UUID().uuidString.lowercased() : sanitized
        return "com.user.\(label)"
    }

    var cronTag: String {
        // Strip newlines/carriage returns to prevent cron line injection
        let safeLabel = launchdLabel
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "# CronTask:\(safeLabel)"
    }

    var isEnabled: Bool {
        status.state == .enabled || status.state == .running
    }

    // Sortable key paths for Table columns
    var statusName: String { status.state.rawValue }
    var triggerTypeName: String { trigger.type.rawValue }
    var backendName: String { backend.rawValue }
    var lastRunDate: Date { status.lastRun ?? .distantPast }

    /// Characters allowed in launchd labels (reverse DNS convention).
    private static let labelAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    func validate() -> [String] {
        var errors: [String] = []

        let trimmedLabel = launchdLabel.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty {
            errors.append("Task label is required")
        } else {
            if trimmedLabel.rangeOfCharacter(from: Self.labelAllowedCharacters.inverted) != nil {
                errors.append("Task label may only contain letters, numbers, '.', '-', and '_'")
            }
            if trimmedLabel.count > 255 {
                errors.append("Task label is too long (max 255 characters)")
            }
        }

        errors.append(contentsOf: action.validate())
        errors.append(contentsOf: trigger.validate())

        if backend == .cron && !trigger.type.supportsCron {
            errors.append("Trigger type '\(trigger.type.rawValue)' is not supported by cron backend")
        }

        return errors
    }

    mutating func enable() {
        status.state = .enabled
        modifiedAt = Date()
    }

    mutating func disable() {
        status.state = .disabled
        modifiedAt = Date()
    }

    mutating func markRunning() {
        status.state = .running
    }

    mutating func recordExecution(_ result: TaskExecutionResult) {
        status.lastRun = result.endTime
        status.lastResult = result
        status.runCount += 1
        if !result.success {
            status.failureCount += 1
        }
        status.state = .enabled
    }
}

extension ScheduledTask {
    static var example: ScheduledTask {
        ScheduledTask(
            name: "Backup Documents",
            description: "Daily backup of Documents folder",
            backend: .launchd,
            action: TaskAction(
                type: .shellScript,
                path: "/usr/bin/rsync",
                arguments: ["-av", "~/Documents", "~/Backups/Documents"]
            ),
            trigger: .calendar(minute: 0, hour: 2),
            status: TaskStatus(state: .enabled),
            launchdLabel: "com.user.backup-documents"
        )
    }
}
