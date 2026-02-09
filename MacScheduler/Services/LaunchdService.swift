//
//  LaunchdService.swift
//  MacScheduler
//
//  Service for managing tasks via launchd plists.
//

import Foundation

class LaunchdService: SchedulerService {
    static let shared = LaunchdService()
    let backend: SchedulerBackend = .launchd

    private let fileManager = FileManager.default
    private let shellExecutor = ShellExecutor.shared
    private let plistGenerator = PlistGenerator()

    private var userLaunchAgentsDirectory: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents")
    }

    /// All directories to scan for launchd plists.
    private var allLaunchDirectories: [(url: URL, isUserWritable: Bool)] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), true),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), false),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), false),
        ]
    }

    private init() {
        ensureLaunchAgentsDirectoryExists()
    }

    private func ensureLaunchAgentsDirectoryExists() {
        try? fileManager.createDirectory(at: userLaunchAgentsDirectory,
                                         withIntermediateDirectories: true)
    }

    /// Default path for new tasks (in user LaunchAgents).
    private func defaultPlistURL(for task: ScheduledTask) -> URL {
        userLaunchAgentsDirectory.appendingPathComponent(task.plistFileName)
    }

    /// Resolve the actual plist path: use stored path if available, otherwise construct from label.
    private func resolvedPlistPath(for task: ScheduledTask) -> String {
        if let path = task.plistFilePath, fileManager.fileExists(atPath: path) {
            return path
        }
        return defaultPlistURL(for: task).path
    }

    func install(task: ScheduledTask) async throws {
        let plistContent = plistGenerator.generate(for: task)
        let plistURL = defaultPlistURL(for: task)

        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            throw SchedulerError.plistCreationFailed(error.localizedDescription)
        }
    }

    func uninstall(task: ScheduledTask) async throws {
        let isLoaded = await isLoaded(label: task.launchdLabel)
        if isLoaded {
            try await disable(task: task)
        }

        let path = resolvedPlistPath(for: task)
        if fileManager.fileExists(atPath: path) {
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                throw SchedulerError.fileSystemError(error.localizedDescription)
            }
        }
    }

    func enable(task: ScheduledTask) async throws {
        let path = resolvedPlistPath(for: task)

        guard fileManager.fileExists(atPath: path) else {
            try await install(task: task)
            let newPath = defaultPlistURL(for: task).path
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["load", newPath]
            )
            if result.exitCode != 0 && !result.standardError.contains("already loaded") {
                throw SchedulerError.plistLoadFailed(result.standardError)
            }
            return
        }

        let result = try await shellExecutor.execute(
            command: "/bin/launchctl",
            arguments: ["load", path]
        )

        if result.exitCode != 0 && !result.standardError.contains("already loaded") {
            throw SchedulerError.plistLoadFailed(result.standardError)
        }
    }

    func disable(task: ScheduledTask) async throws {
        let path = resolvedPlistPath(for: task)

        guard fileManager.fileExists(atPath: path) else {
            return
        }

        let result = try await shellExecutor.execute(
            command: "/bin/launchctl",
            arguments: ["unload", path]
        )

        if result.exitCode != 0 && !result.standardError.contains("Could not find") {
            throw SchedulerError.plistUnloadFailed(result.standardError)
        }
    }

    /// Robust update: unload old label, delete old plist, write new plist, load new.
    func updateTask(oldTask: ScheduledTask, newTask: ScheduledTask) async throws {
        // 1. Always try to unload old task (don't check isLoaded — avoids stale state)
        let oldPath = resolvedPlistPath(for: oldTask)
        if fileManager.fileExists(atPath: oldPath) {
            let _ = try? await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["unload", oldPath]
            )
        }

        // 2. Delete old plist file (handles label/filename change)
        if fileManager.fileExists(atPath: oldPath) {
            try? fileManager.removeItem(atPath: oldPath)
        }

        // 3. Write new plist file (always to user LaunchAgents)
        let plistContent = plistGenerator.generate(for: newTask)
        let newPlistURL = defaultPlistURL(for: newTask)
        do {
            try plistContent.write(to: newPlistURL, atomically: true, encoding: .utf8)
        } catch {
            throw SchedulerError.plistCreationFailed(error.localizedDescription)
        }

        // 4. Always load new plist to register with launchd
        let loadResult = try await shellExecutor.execute(
            command: "/bin/launchctl",
            arguments: ["load", newPlistURL.path]
        )
        if loadResult.exitCode != 0 && !loadResult.standardError.contains("already loaded") {
            throw SchedulerError.plistLoadFailed(loadResult.standardError)
        }

        // 5. If task should be disabled, unload after registering
        if !newTask.isEnabled {
            let _ = try? await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["unload", newPlistURL.path]
            )
        }
    }

    func runNow(task: ScheduledTask) async throws -> TaskExecutionResult {
        let startTime = Date()

        let result: ShellResult
        switch task.action.type {
        case .executable:
            let directResult = try await shellExecutor.execute(
                command: task.action.path,
                arguments: task.action.arguments,
                workingDirectory: task.action.workingDirectory,
                environment: task.action.environmentVariables
            )
            if directResult.exitCode == 126 {
                let fullCommand = ([task.action.path] + task.action.arguments)
                    .map { shellQuote($0) }
                    .joined(separator: " ")
                result = try await shellExecutor.execute(
                    command: "/bin/sh",
                    arguments: ["-c", fullCommand],
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
            } else {
                result = directResult
            }
        case .shellScript:
            let shellBinaries = ["bash", "sh", "zsh", "fish", "dash"]
            let pathIsShellBinary = shellBinaries.contains(where: { task.action.path.hasSuffix("/\($0)") })

            if let script = task.action.scriptContent, !script.isEmpty {
                let shell = pathIsShellBinary ? task.action.path : "/bin/bash"
                result = try await shellExecutor.executeScript(
                    script,
                    shell: shell,
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
            } else if pathIsShellBinary {
                result = try await shellExecutor.execute(
                    command: task.action.path,
                    arguments: task.action.arguments,
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
            } else if !task.action.path.isEmpty {
                result = try await shellExecutor.execute(
                    command: "/bin/bash",
                    arguments: [task.action.path] + task.action.arguments,
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
            } else {
                result = ShellResult(exitCode: 1, standardOutput: "", standardError: "No script content or path provided")
            }
        case .appleScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                result = try await shellExecutor.execute(
                    command: "/usr/bin/osascript",
                    arguments: ["-e", script]
                )
            } else {
                result = try await shellExecutor.execute(
                    command: "/usr/bin/osascript",
                    arguments: [task.action.path]
                )
            }
        }

        let endTime = Date()

        return TaskExecutionResult(
            taskId: task.id,
            startTime: startTime,
            endTime: endTime,
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }

    func isInstalled(task: ScheduledTask) async -> Bool {
        let path = resolvedPlistPath(for: task)
        return fileManager.fileExists(atPath: path)
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        await isLoaded(label: task.launchdLabel)
    }

    /// Check if a launchd label is currently loaded.
    func isLoaded(label: String) async -> Bool {
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["list", label]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Read last run time from native launchd sources (stdout/stderr file mtime).
    func getLastRunTime(for task: ScheduledTask) -> Date? {
        if let outPath = task.standardOutPath, !outPath.isEmpty,
           let attrs = try? fileManager.attributesOfItem(atPath: outPath),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime
        }
        if let errPath = task.standardErrorPath, !errPath.isEmpty,
           let attrs = try? fileManager.attributesOfItem(atPath: errPath),
           let mtime = attrs[.modificationDate] as? Date {
            return mtime
        }
        return nil
    }

    /// Read run count and last exit code from launchctl print.
    func getLaunchdInfo(for task: ScheduledTask) async -> (runs: Int, lastExitCode: Int32)? {
        let uid = getuid()
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["print", "gui/\(uid)/\(task.launchdLabel)"],
                timeout: 5.0
            )
            guard result.exitCode == 0 else { return nil }

            var runs = 0
            var lastExit: Int32 = 0

            for line in result.standardOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("runs = ") {
                    runs = Int(trimmed.dropFirst("runs = ".count)) ?? 0
                } else if trimmed.hasPrefix("last exit reason = ") {
                    if let bracketRange = trimmed.range(of: #"\[(\d+)\]"#, options: .regularExpression) {
                        let codeStr = trimmed[bracketRange].dropFirst().dropLast()
                        lastExit = Int32(codeStr) ?? 0
                    }
                }
            }
            return (runs, lastExit)
        } catch {
            return nil
        }
    }

    /// Get all loaded launchd labels in a single call (much faster than per-task isLoaded).
    func getAllLoadedLabels() async -> Set<String> {
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["list"],
                timeout: 10.0
            )
            guard result.exitCode == 0 else { return [] }
            var labels = Set<String>()
            for line in result.standardOutput.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 3 {
                    labels.insert(parts[2])
                }
            }
            return labels
        } catch {
            return []
        }
    }

    /// Discover tasks from all launchd directories.
    func discoverTasks() async throws -> [ScheduledTask] {
        let loadedLabels = await getAllLoadedLabels()
        var tasks: [ScheduledTask] = []

        for dir in allLaunchDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(at: dir.url,
                                                                       includingPropertiesForKeys: nil) else {
                continue
            }

            for url in contents where url.pathExtension == "plist" {
                if var task = parsePlist(at: url, isUserWritable: dir.isUserWritable) {
                    task.status.state = loadedLabels.contains(task.launchdLabel) ? .enabled : .disabled
                    task.plistFilePath = url.path
                    tasks.append(task)
                }
            }
        }

        return tasks
    }

    private func parsePlist(at url: URL, isUserWritable: Bool = true) -> ScheduledTask? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        guard let label = plist["Label"] as? String else {
            return nil
        }

        let uuid = ScheduledTask.uuidFromLabel(label)

        var task = ScheduledTask(id: uuid)
        task.backend = .launchd
        task.launchdLabel = label
        task.isReadOnly = !isUserWritable

        // Read custom metadata if present, otherwise derive name from label
        if let customName = plist["MacSchedulerName"] as? String {
            task.name = customName
        } else {
            task.name = formatLabelAsName(label)
        }

        if let customDesc = plist["MacSchedulerDescription"] as? String {
            task.description = customDesc
        }

        if let program = plist["Program"] as? String {
            task.action.path = program
            task.action.type = .executable
        }

        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            task.action.path = args[0]
            task.action.arguments = Array(args.dropFirst())

            if args[0].hasSuffix("bash") || args[0].hasSuffix("sh") || args[0].hasSuffix("zsh") {
                task.action.type = .shellScript
                if args.count > 2 && args[1] == "-c" {
                    task.action.scriptContent = args[2]
                }
            } else if args[0].hasSuffix("osascript") {
                task.action.type = .appleScript
                if args.count > 2 && args[1] == "-e" {
                    task.action.scriptContent = args[2]
                }
            } else {
                task.action.type = .executable
            }
        }

        if let workDir = plist["WorkingDirectory"] as? String {
            task.action.workingDirectory = workDir
        }

        if let envVars = plist["EnvironmentVariables"] as? [String: String] {
            task.action.environmentVariables = envVars
        }

        if let calendar = plist["StartCalendarInterval"] as? [String: Int] {
            var schedule = CalendarSchedule()
            schedule.minute = calendar["Minute"]
            schedule.hour = calendar["Hour"]
            schedule.day = calendar["Day"]
            schedule.weekday = calendar["Weekday"]
            schedule.month = calendar["Month"]
            task.trigger = TaskTrigger(type: .calendar, calendarSchedule: schedule)
        } else if let calendarArray = plist["StartCalendarInterval"] as? [[String: Int]] {
            if let first = calendarArray.first {
                var schedule = CalendarSchedule()
                schedule.minute = first["Minute"]
                schedule.hour = first["Hour"]
                schedule.day = first["Day"]
                schedule.weekday = first["Weekday"]
                schedule.month = first["Month"]
                task.trigger = TaskTrigger(type: .calendar, calendarSchedule: schedule)
                task.description = "Multiple schedules (\(calendarArray.count) triggers)"
            }
        } else if let interval = plist["StartInterval"] as? Int {
            task.trigger = TaskTrigger(type: .interval, intervalSeconds: interval)
        } else if plist["RunAtLoad"] as? Bool == true {
            task.trigger = TaskTrigger(type: .atLogin)
        } else if plist["KeepAlive"] != nil {
            task.trigger = TaskTrigger(type: .onDemand)
        } else {
            task.trigger = TaskTrigger(type: .onDemand)
        }

        task.runAtLoad = plist["RunAtLoad"] as? Bool ?? false

        if let keepAlive = plist["KeepAlive"] as? Bool {
            task.keepAlive = keepAlive
        } else if plist["KeepAlive"] is [String: Any] {
            task.keepAlive = true
        }

        task.standardOutPath = plist["StandardOutPath"] as? String
        task.standardErrorPath = plist["StandardErrorPath"] as? String

        return task
    }

    /// Shell-quote a string by wrapping in single quotes and escaping embedded single quotes.
    private func shellQuote(_ string: String) -> String {
        if string.isEmpty { return "''" }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func formatLabelAsName(_ label: String) -> String {
        var name = label

        let prefixes = ["com.", "org.", "io.", "net.", "app."]
        for prefix in prefixes {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                if let dotIndex = name.firstIndex(of: ".") {
                    name = String(name[name.index(after: dotIndex)...])
                }
                break
            }
        }

        name = name.replacingOccurrences(of: ".", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")
        name = name.replacingOccurrences(of: "_", with: " ")

        return name.capitalized
    }
}
