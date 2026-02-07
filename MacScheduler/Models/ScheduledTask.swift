//
//  ScheduledTask.swift
//  MacScheduler
//
//  The core model representing a scheduled task.
//

import Foundation

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
    var externalLabel: String?
    var isExternal: Bool

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
         externalLabel: String? = nil,
         isExternal: Bool = false) {
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
        self.externalLabel = externalLabel
        self.isExternal = isExternal
    }

    var launchdLabel: String {
        if let external = externalLabel {
            return external
        }
        return "com.macscheduler.task.\(id.uuidString.lowercased())"
    }

    var plistFileName: String {
        "\(launchdLabel).plist"
    }

    static func uuidFromLabel(_ label: String) -> UUID {
        // Use a deterministic hash (djb2 variant) to generate consistent UUIDs
        let data = Data(label.utf8)
        var uuidBytes = [UInt8](repeating: 0, count: 16)

        // Generate 16 bytes using multiple hash rounds
        for round in 0..<16 {
            var hash: UInt64 = 5381
            for byte in data {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            // Mix in the round number to get different bytes
            hash = hash &+ UInt64(round) &* 31
            uuidBytes[round] = UInt8(truncatingIfNeeded: hash)
        }

        return UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                          uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                          uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                          uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }

    var cronTag: String {
        "# MacScheduler:\(id.uuidString)"
    }

    var isEnabled: Bool {
        status.state == .enabled || status.state == .running
    }

    // Sortable key paths for Table columns
    var statusName: String { status.state.rawValue }
    var triggerTypeName: String { trigger.type.rawValue }
    var backendName: String { backend.rawValue }
    var lastRunDate: Date { status.lastRun ?? .distantPast }

    func validate() -> [String] {
        if isExternal {
            return []
        }

        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Task name is required")
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

    static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        lhs.id == rhs.id
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
            isExternal: false
        )
    }
}
