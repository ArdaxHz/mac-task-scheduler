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
    @Published var location: TaskLocation = .userAgent
    @Published var userName: String = ""

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
        location = task.location
        userName = task.userName ?? ""
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
        location = .userAgent
        userName = ""
        validationErrors = []
        showValidationErrors = false
    }

    /// Default log directory for task output.
    static var defaultLogDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacScheduler").path
    }

    /// Allowlist-sanitize a string for use in filenames: only [a-zA-Z0-9._-] pass through.
    private static let filenameAllowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Set stdout and stderr paths to the default log directory using the task label.
    func setDefaultOutputPaths() {
        let logDir = Self.defaultLogDirectory
        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true)
        let sanitizedLabel = taskLabel.isEmpty ? "task" : String(taskLabel.unicodeScalars.map { scalar in
            if Self.filenameAllowedChars.contains(scalar) {
                return Character(scalar)
            }
            return Character("_")
        })
        if standardOutPath.isEmpty {
            standardOutPath = "\(logDir)/\(sanitizedLabel).stdout.log"
        }
        if standardErrorPath.isEmpty {
            standardErrorPath = "\(logDir)/\(sanitizedLabel).stderr.log"
        }
    }

    /// Auto-generate label from name if label is empty or was auto-generated.
    func updateLabelFromName() {
        if !isEditing && (taskLabel.isEmpty || taskLabel == ScheduledTask.labelFromName(name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(name.dropLast()))) {
            taskLabel = ScheduledTask.labelFromName(name)
        }
    }

    /// Check if a path is safe to write script content back to.
    /// Prevents overwriting system files, dotfiles, or non-script files.
    static func isSafeScriptWritePath(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Must be an existing file (don't create new files in arbitrary locations)
        guard FileManager.default.fileExists(atPath: expandedPath) else { return false }

        // Block writing to system directories
        let blockedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/Library", "/private/var", "/etc"]
        for prefix in blockedPrefixes {
            if expandedPath.hasPrefix(prefix) { return false }
        }

        // Block dotfiles (e.g. .bashrc, .zshrc, .ssh/config)
        let components = expandedPath.components(separatedBy: "/")
        for component in components where component.hasPrefix(".") && component != "." && component != ".." {
            return false
        }

        return true
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

    /// Characters allowed in launchd labels (reverse DNS convention).
    private static let labelAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    func validate() -> Bool {
        validationErrors = []

        // --- Name ---
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            validationErrors.append("Task name is required")
        } else if trimmedName.count > 255 {
            validationErrors.append("Task name is too long (max 255 characters)")
        }

        // --- Label ---
        let trimmedLabel = taskLabel.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty {
            validationErrors.append("Task label is required")
        } else if trimmedLabel.contains("/") || trimmedLabel.contains("..") {
            validationErrors.append("Task label must not contain '/' or '..'")
        } else if trimmedLabel.rangeOfCharacter(from: Self.labelAllowedCharacters.inverted) != nil {
            validationErrors.append("Task label may only contain letters, numbers, '.', '-', and '_'")
        } else if trimmedLabel.count > 255 {
            validationErrors.append("Task label is too long (max 255 characters)")
        }

        // --- Executable path ---
        switch actionType {
        case .executable:
            if executablePath.isEmpty {
                validationErrors.append("Executable path is required")
            } else {
                validatePath(executablePath, label: "Executable path")
            }
        case .shellScript:
            if executablePath.isEmpty && scriptContent.isEmpty {
                validationErrors.append("Script path or content is required")
            } else if !executablePath.isEmpty {
                validatePath(executablePath, label: "Script path")
            }
        case .appleScript:
            if executablePath.isEmpty && scriptContent.isEmpty {
                validationErrors.append("AppleScript path or content is required")
            } else if !executablePath.isEmpty {
                validatePath(executablePath, label: "AppleScript path")
            }
        }

        // --- Working directory ---
        if !workingDirectory.isEmpty {
            validatePath(workingDirectory, label: "Working directory", mustBeDirectory: true)
        }

        // --- stdout/stderr paths ---
        if !standardOutPath.isEmpty {
            validateOutputPath(standardOutPath, label: "Standard output path")
        }
        if !standardErrorPath.isEmpty {
            validateOutputPath(standardErrorPath, label: "Standard error path")
        }

        // --- Trigger ---
        if backend == .cron && !triggerType.supportsCron {
            validationErrors.append("'\(triggerType.rawValue)' trigger is not supported by cron")
        }

        if triggerType == .interval {
            if intervalValue <= 0 {
                validationErrors.append("Interval must be greater than 0")
            } else {
                let (product, overflow) = intervalValue.multipliedReportingOverflow(by: intervalUnit.multiplier)
                if overflow || product > 31_536_000 {
                    validationErrors.append("Interval must not exceed 1 year")
                }
            }
        }

        // --- Calendar schedule bounds ---
        if triggerType == .calendar {
            if scheduleMinute < 0 || scheduleMinute > 59 {
                validationErrors.append("Minute must be between 0 and 59")
            }
            if scheduleHour < 0 || scheduleHour > 23 {
                validationErrors.append("Hour must be between 0 and 23")
            }
            if let day = scheduleDay, (day < 1 || day > 31) {
                validationErrors.append("Day must be between 1 and 31")
            }
            if let weekday = scheduleWeekday, (weekday < 0 || weekday > 6) {
                validationErrors.append("Weekday must be between 0 (Sun) and 6 (Sat)")
            }
            if let month = scheduleMonth, (month < 1 || month > 12) {
                validationErrors.append("Month must be between 1 and 12")
            }
        }

        // --- UserName ---
        if !userName.isEmpty {
            let userNameAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            if userName.rangeOfCharacter(from: userNameAllowed.inverted) != nil {
                validationErrors.append("User name may only contain letters, numbers, '_', and '-'")
            } else if userName.count > 255 {
                validationErrors.append("User name is too long (max 255 characters)")
            }
        }

        showValidationErrors = !validationErrors.isEmpty
        return validationErrors.isEmpty
    }

    /// Validate a file/directory path for safety.
    private func validatePath(_ path: String, label: String, mustBeDirectory: Bool = false) {
        let expanded = NSString(string: path).expandingTildeInPath

        // Reject null bytes (path traversal via null byte injection)
        if expanded.contains("\0") {
            validationErrors.append("\(label) contains invalid characters")
            return
        }

        // Must be an absolute path
        if !expanded.hasPrefix("/") {
            validationErrors.append("\(label) must be an absolute path")
            return
        }

        // Reject paths in system-critical directories for writing
        let systemDirs = ["/System", "/usr/bin", "/usr/sbin", "/sbin", "/bin"]
        for dir in systemDirs {
            if expanded.hasPrefix(dir + "/") || expanded == dir {
                validationErrors.append("\(label) must not point to a system directory")
                return
            }
        }
    }

    /// Validate an output path (stdout/stderr) for safety.
    private func validateOutputPath(_ path: String, label: String) {
        let expanded = NSString(string: path).expandingTildeInPath

        if expanded.contains("\0") {
            validationErrors.append("\(label) contains invalid characters")
            return
        }

        if !expanded.hasPrefix("/") {
            validationErrors.append("\(label) must be an absolute path")
            return
        }

        // Resolve symlinks to prevent symlink attacks
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path

        // Block system-critical directories
        let systemDirs = ["/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/etc"]
        for dir in systemDirs {
            if resolved.hasPrefix(dir + "/") || resolved == dir {
                validationErrors.append("\(label) must not point to a system directory")
                return
            }
        }

        // Verify parent directory exists
        let parentDir = (resolved as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parentDir) {
            validationErrors.append("\(label) parent directory does not exist")
            return
        }
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

    /// Get available user accounts for the UserName picker.
    static var systemUsers: [String] {
        var users: [String] = []
        let homeDir = "/Users"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: homeDir) {
            for name in contents.sorted() {
                let path = "\(homeDir)/\(name)"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                   isDir.boolValue,
                   !name.hasPrefix("."),
                   name != "Shared" {
                    users.append(name)
                }
            }
        }
        // Add common system accounts
        users.append(contentsOf: ["root", "nobody", "_www"])
        return users
    }

    /// Unicode scalars that can manipulate text rendering (bidi overrides, zero-width chars).
    private static let dangerousUnicodeScalars: Set<Unicode.Scalar> = [
        "\u{200B}", // Zero-width space
        "\u{200C}", // Zero-width non-joiner
        "\u{200D}", // Zero-width joiner
        "\u{200E}", // Left-to-right mark
        "\u{200F}", // Right-to-left mark
        "\u{202A}", // Left-to-right embedding
        "\u{202B}", // Right-to-left embedding
        "\u{202C}", // Pop directional formatting
        "\u{202D}", // Left-to-right override
        "\u{202E}", // Right-to-left override (can visually hide malicious code)
        "\u{2066}", // Left-to-right isolate
        "\u{2067}", // Right-to-left isolate
        "\u{2068}", // First strong isolate
        "\u{2069}", // Pop directional isolate
        "\u{FEFF}", // BOM / zero-width no-break space
    ]

    /// Strip control characters and dangerous Unicode from a single-line field (name, label, description).
    /// Does NOT allow newlines — use sanitizeScriptContent for multi-line script content.
    private static func sanitizeNameField(_ string: String) -> String {
        string.unicodeScalars.filter { scalar in
            guard scalar.value != 0 else { return false }
            guard !dangerousUnicodeScalars.contains(scalar) else { return false }
            if scalar.isASCII {
                return scalar.value >= 32 || scalar.value == 9 // printable + tab
            }
            return true
        }.map { String($0) }.joined()
    }

    /// Strip control characters and dangerous Unicode from script content.
    /// Allows newlines and tabs which are valid in scripts.
    private static func sanitizeScriptContent(_ string: String) -> String {
        string.unicodeScalars.filter { scalar in
            guard scalar.value != 0 else { return false }
            guard !dangerousUnicodeScalars.contains(scalar) else { return false }
            if scalar.isASCII {
                return scalar.value >= 32 || scalar.value == 10 || scalar.value == 9 || scalar.value == 13
            }
            return true
        }.map { String($0) }.joined()
    }

    /// Strip null bytes and control characters from paths.
    private static func sanitizePath(_ string: String) -> String {
        string.filter { char in
            guard let ascii = char.asciiValue else { return true }
            return ascii >= 32 // Block all control chars including null, newline, tab in paths
        }
    }

    func buildTask() -> ScheduledTask {
        // Sanitize all user inputs before building the task
        let cleanPath = Self.sanitizePath(executablePath)
        let cleanWorkDir = Self.sanitizePath(workingDirectory)
        let cleanLabel = Self.sanitizeNameField(taskLabel).trimmingCharacters(in: .whitespaces)
        let cleanName = Self.sanitizeNameField(name).trimmingCharacters(in: .whitespaces)
        let cleanDescription = Self.sanitizeNameField(taskDescription)
        let cleanStdOut = Self.sanitizePath(standardOutPath)
        let cleanStdErr = Self.sanitizePath(standardErrorPath)

        // For file-based scripts, write edited content back to the file
        // and don't embed it inline in the plist
        let cleanScript = Self.sanitizeScriptContent(scriptContent)
        var inlineScript: String? = nil
        if (actionType == .shellScript || actionType == .appleScript) && !cleanScript.isEmpty {
            if !cleanPath.isEmpty && Self.isSafeScriptWritePath(cleanPath) {
                // File-based script: save content back to the file
                try? cleanScript.write(toFile: cleanPath, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cleanPath)
            } else if cleanPath.isEmpty {
                // No file path: use as inline script content
                inlineScript = cleanScript
            }
            // If executablePath is set but not safe to write, reference the file without modifying it
        }

        let action = TaskAction(
            id: editingTask?.action.id ?? UUID(),
            type: actionType,
            path: cleanPath,
            arguments: arguments.isEmpty ? [] : Self.sanitizeNameField(arguments)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty },
            workingDirectory: cleanWorkDir.isEmpty ? nil : cleanWorkDir,
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
            let (product, overflow) = intervalValue.multipliedReportingOverflow(by: intervalUnit.multiplier)
            let clampedInterval = overflow ? 31_536_000 : min(product, 31_536_000)
            trigger = TaskTrigger(
                id: editingTask?.trigger.id ?? UUID(),
                type: .interval,
                intervalSeconds: max(1, clampedInterval)
            )
        case .atLogin:
            trigger = .atLogin
        case .atStartup:
            trigger = .atStartup
        case .onDemand:
            trigger = .onDemand
        }

        return ScheduledTask(
            id: editingTask?.id ?? ScheduledTask.uuidFromLabel(cleanLabel),
            name: cleanName,
            description: cleanDescription,
            backend: backend,
            action: action,
            trigger: trigger,
            status: editingTask?.status ?? TaskStatus(state: .enabled),
            createdAt: editingTask?.createdAt ?? Date(),
            modifiedAt: Date(),
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            standardOutPath: cleanStdOut.isEmpty ? nil : cleanStdOut,
            standardErrorPath: cleanStdErr.isEmpty ? nil : cleanStdErr,
            launchdLabel: cleanLabel,
            isReadOnly: editingTask?.isReadOnly ?? false,
            plistFilePath: editingTask?.plistFilePath,
            location: location,
            userName: userName.isEmpty ? nil : userName
        )
    }
}
