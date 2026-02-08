//
//  TaskEditorViewModel.swift
//  MacScheduler
//
//  ViewModel for creating and editing scheduled tasks.
//

import Foundation
import SwiftUI

@MainActor
class TaskEditorViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var taskDescription: String = ""
    @Published var taskLabel: String = ""
    @Published var backend: SchedulerBackend = .launchd
    @Published var actionType: TaskActionType = .executable
    @Published var executablePath: String = ""
    @Published var arguments: String = ""
    @Published var workingDirectory: String = ""
    @Published var scriptContent: String = ""
    @Published var triggerType: TriggerType = .onDemand
    @Published var scheduleMinute: Int = 0
    @Published var scheduleHour: Int = 0
    @Published var scheduleDay: Int? = nil
    @Published var scheduleWeekday: Int? = nil
    @Published var scheduleMonth: Int? = nil
    @Published var intervalValue: Int = 60
    @Published var intervalUnit: IntervalUnit = .minutes
    @Published var runAtLoad: Bool = false
    @Published var keepAlive: Bool = false
    @Published var standardOutPath: String = ""
    @Published var standardErrorPath: String = ""

    @Published var validationErrors: [String] = []
    @Published var showValidationErrors = false

    private var editingTask: ScheduledTask?

    var isEditing: Bool {
        editingTask != nil
    }

    var title: String {
        isEditing ? "Edit Task" : "New Task"
    }

    enum IntervalUnit: String, CaseIterable {
        case seconds = "Seconds"
        case minutes = "Minutes"
        case hours = "Hours"
        case days = "Days"

        var multiplier: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86400
            }
        }
    }

    init() {}

    init(task: ScheduledTask) {
        loadTask(task)
    }

    func loadTask(_ task: ScheduledTask) {
        editingTask = task
        name = task.name
        taskDescription = task.description
        taskLabel = task.launchdLabel
        backend = task.backend

        actionType = task.action.type
        workingDirectory = task.action.workingDirectory ?? ""
        scriptContent = task.action.scriptContent ?? ""

        // For shell/apple scripts with file-based content, read the script file
        if scriptContent.isEmpty && (task.action.type == .shellScript || task.action.type == .appleScript) {
            let candidatePath = resolveScriptPath(task)
            if let path = candidatePath, FileManager.default.fileExists(atPath: path) {
                scriptContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            }
        }

        // For shell scripts, extract the actual script path from arguments
        if task.action.type == .shellScript {
            let path = task.action.path
            let shellBinaries = ["bash", "sh", "zsh", "fish", "dash"]
            let isShellBinary = shellBinaries.contains(where: { path.hasSuffix("/\($0)") })
            if isShellBinary {
                if let firstArg = task.action.arguments.first, !firstArg.hasPrefix("-") {
                    executablePath = firstArg
                    arguments = task.action.arguments.dropFirst().joined(separator: " ")
                } else if task.action.arguments.first == "-c" {
                    executablePath = ""
                    arguments = ""
                } else {
                    executablePath = ""
                    arguments = task.action.arguments.joined(separator: " ")
                }
            } else {
                executablePath = path
                arguments = task.action.arguments.joined(separator: " ")
            }
        } else if task.action.type == .appleScript {
            let path = task.action.path
            if path.hasSuffix("osascript") {
                if let firstArg = task.action.arguments.first, !firstArg.hasPrefix("-") {
                    executablePath = firstArg
                    arguments = task.action.arguments.dropFirst().joined(separator: " ")
                } else if task.action.arguments.first == "-e" {
                    executablePath = ""
                    arguments = ""
                } else {
                    executablePath = ""
                    arguments = task.action.arguments.joined(separator: " ")
                }
            } else {
                executablePath = path
                arguments = task.action.arguments.joined(separator: " ")
            }
        } else {
            executablePath = task.action.path
            arguments = task.action.arguments.joined(separator: " ")
        }

        triggerType = task.trigger.type

        if let schedule = task.trigger.calendarSchedule {
            scheduleMinute = schedule.minute ?? 0
            scheduleHour = schedule.hour ?? 0
            scheduleDay = schedule.day
            scheduleWeekday = schedule.weekday
            scheduleMonth = schedule.month
        }

        if let seconds = task.trigger.intervalSeconds {
            if seconds % 86400 == 0 {
                intervalUnit = .days
                intervalValue = seconds / 86400
            } else if seconds % 3600 == 0 {
                intervalUnit = .hours
                intervalValue = seconds / 3600
            } else if seconds % 60 == 0 {
                intervalUnit = .minutes
                intervalValue = seconds / 60
            } else {
                intervalUnit = .seconds
                intervalValue = seconds
            }
        }

        runAtLoad = task.runAtLoad
        keepAlive = task.keepAlive
        standardOutPath = task.standardOutPath ?? ""
        standardErrorPath = task.standardErrorPath ?? ""
    }

    func reset() {
        editingTask = nil
        name = ""
        taskDescription = ""
        taskLabel = ""
        backend = .launchd
        actionType = .executable
        executablePath = ""
        arguments = ""
        workingDirectory = ""
        scriptContent = ""
        triggerType = .onDemand
        scheduleMinute = 0
        scheduleHour = 0
        scheduleDay = nil
        scheduleWeekday = nil
        scheduleMonth = nil
        intervalValue = 60
        intervalUnit = .minutes
        runAtLoad = false
        keepAlive = false
        standardOutPath = ""
        standardErrorPath = ""
        validationErrors = []
        showValidationErrors = false
    }

    /// Auto-generate label from name if label is empty or was auto-generated.
    func updateLabelFromName() {
        if !isEditing && (taskLabel.isEmpty || taskLabel == ScheduledTask.labelFromName(name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(name.dropLast()))) {
            taskLabel = ScheduledTask.labelFromName(name)
        }
    }

    /// Check if a path is inside a macOS TCC-protected directory.
    static func isTCCProtected(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedDirs = [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
        ]
        let expandedPath = NSString(string: path).expandingTildeInPath
        return protectedDirs.contains { expandedPath.hasPrefix($0) }
    }

    func validate() -> Bool {
        validationErrors = []

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            validationErrors.append("Task name is required")
        }

        if taskLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            validationErrors.append("Task label is required")
        }

        switch actionType {
        case .executable:
            if executablePath.isEmpty {
                validationErrors.append("Executable path is required")
            }
        case .shellScript:
            if executablePath.isEmpty && scriptContent.isEmpty {
                validationErrors.append("Script path or content is required")
            }
        case .appleScript:
            if executablePath.isEmpty && scriptContent.isEmpty {
                validationErrors.append("AppleScript path or content is required")
            }
        }


        if backend == .cron && !triggerType.supportsCron {
            validationErrors.append("'\(triggerType.rawValue)' trigger is not supported by cron")
        }

        if triggerType == .interval && intervalValue <= 0 {
            validationErrors.append("Interval must be greater than 0")
        }

        showValidationErrors = !validationErrors.isEmpty
        return validationErrors.isEmpty
    }

    /// Scripts directory from user preferences, falling back to ~/Library/Scripts.
    static var scriptsDirectory: String {
        let custom = UserDefaults.standard.string(forKey: "scriptsDirectory") ?? ""
        if !custom.isEmpty { return custom }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Scripts").path
    }

    /// Copy a file from a TCC-protected path to the scripts directory and return the new path.
    @discardableResult
    func copyFileToScriptsDirectory(from sourcePath: String) -> String? {
        let fm = FileManager.default
        let scriptsDir = Self.scriptsDirectory
        let destDir = URL(fileURLWithPath: scriptsDir)

        // Ensure scripts directory exists
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let fileName = (sourcePath as NSString).lastPathComponent
        var destPath = destDir.appendingPathComponent(fileName).path

        // Handle name collision
        if fm.fileExists(atPath: destPath) {
            let baseName = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            var counter = 1
            repeat {
                let newName = ext.isEmpty ? "\(baseName)_\(counter)" : "\(baseName)_\(counter).\(ext)"
                destPath = destDir.appendingPathComponent(newName).path
                counter += 1
            } while fm.fileExists(atPath: destPath)
        }

        do {
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
            // Make executable
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
            return destPath
        } catch {
            return nil
        }
    }

    /// Resolve the script file path from a task's action (shell binary + arguments pattern).
    private func resolveScriptPath(_ task: ScheduledTask) -> String? {
        let path = task.action.path
        let shellBinaries = ["bash", "sh", "zsh", "fish", "dash", "osascript"]
        let isShellBinary = shellBinaries.contains(where: { path.hasSuffix("/\($0)") })

        if isShellBinary {
            // Script path is typically the first non-flag argument
            for arg in task.action.arguments {
                if !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg) {
                    return arg
                }
            }
        } else if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    func buildTask() -> ScheduledTask {
        // For file-based scripts, write edited content back to the file
        // and don't embed it inline in the plist
        var inlineScript: String? = nil
        if (actionType == .shellScript || actionType == .appleScript) && !scriptContent.isEmpty {
            if !executablePath.isEmpty {
                // File-based script: save content back to the file
                try? scriptContent.write(toFile: executablePath, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
            } else {
                // No file path: use as inline script content
                inlineScript = scriptContent
            }
        }

        let action = TaskAction(
            id: editingTask?.action.id ?? UUID(),
            type: actionType,
            path: executablePath,
            arguments: arguments.isEmpty ? [] : arguments.components(separatedBy: " "),
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            environmentVariables: [:],
            scriptContent: inlineScript
        )

        var trigger: TaskTrigger
        switch triggerType {
        case .calendar:
            trigger = TaskTrigger(
                id: editingTask?.trigger.id ?? UUID(),
                type: .calendar,
                calendarSchedule: CalendarSchedule(
                    minute: scheduleMinute,
                    hour: scheduleHour,
                    day: scheduleDay,
                    weekday: scheduleWeekday,
                    month: scheduleMonth
                )
            )
        case .interval:
            trigger = TaskTrigger(
                id: editingTask?.trigger.id ?? UUID(),
                type: .interval,
                intervalSeconds: intervalValue * intervalUnit.multiplier
            )
        case .atLogin:
            trigger = .atLogin
        case .atStartup:
            trigger = .atStartup
        case .onDemand:
            trigger = .onDemand
        }

        return ScheduledTask(
            id: editingTask?.id ?? ScheduledTask.uuidFromLabel(taskLabel),
            name: name.trimmingCharacters(in: .whitespaces),
            description: taskDescription,
            backend: backend,
            action: action,
            trigger: trigger,
            status: editingTask?.status ?? TaskStatus(state: .enabled),
            createdAt: editingTask?.createdAt ?? Date(),
            modifiedAt: Date(),
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            standardOutPath: standardOutPath.isEmpty ? nil : standardOutPath,
            standardErrorPath: standardErrorPath.isEmpty ? nil : standardErrorPath,
            launchdLabel: taskLabel,
            isReadOnly: editingTask?.isReadOnly ?? false,
            plistFilePath: editingTask?.plistFilePath
        )
    }
}
