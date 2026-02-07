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

    private var launchAgentsDirectory: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents")
    }

    private init() {
        ensureLaunchAgentsDirectoryExists()
    }

    private func ensureLaunchAgentsDirectoryExists() {
        try? fileManager.createDirectory(at: launchAgentsDirectory,
                                         withIntermediateDirectories: true)
    }

    private func plistURL(for task: ScheduledTask) -> URL {
        launchAgentsDirectory.appendingPathComponent(task.plistFileName)
    }

    func install(task: ScheduledTask) async throws {
        let errors = task.validate()
        if !errors.isEmpty {
            throw SchedulerError.invalidTask(errors.joined(separator: "; "))
        }

        let plistContent = plistGenerator.generate(for: task)
        let plistURL = plistURL(for: task)

        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            throw SchedulerError.plistCreationFailed(error.localizedDescription)
        }
    }

    func uninstall(task: ScheduledTask) async throws {
        if await isInstalled(task: task) {
            try await disable(task: task)
        }

        let plistURL = plistURL(for: task)
        if fileManager.fileExists(atPath: plistURL.path) {
            do {
                try fileManager.removeItem(at: plistURL)
            } catch {
                throw SchedulerError.fileSystemError(error.localizedDescription)
            }
        }
    }

    func enable(task: ScheduledTask) async throws {
        let plistURL = plistURL(for: task)

        guard fileManager.fileExists(atPath: plistURL.path) else {
            try await install(task: task)
            return try await enable(task: task)
        }

        let result = try await shellExecutor.execute(
            command: "/bin/launchctl",
            arguments: ["load", plistURL.path]
        )

        if result.exitCode != 0 && !result.standardError.contains("already loaded") {
            throw SchedulerError.plistLoadFailed(result.standardError)
        }
    }

    func disable(task: ScheduledTask) async throws {
        let plistURL = plistURL(for: task)

        guard fileManager.fileExists(atPath: plistURL.path) else {
            return
        }

        let result = try await shellExecutor.execute(
            command: "/bin/launchctl",
            arguments: ["unload", plistURL.path]
        )

        if result.exitCode != 0 && !result.standardError.contains("Could not find") {
            throw SchedulerError.plistUnloadFailed(result.standardError)
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
                // File not executable — retry through shell
                let fullCommand = ([task.action.path] + task.action.arguments)
                    .map { $0.contains(" ") ? "'\($0)'" : $0 }
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
                // Path is the shell itself (e.g. discovered plist) — run arguments through it
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
        let plistURL = plistURL(for: task)
        return fileManager.fileExists(atPath: plistURL.path)
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["list", task.launchdLabel]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func discoverTasks() async throws -> [ScheduledTask] {
        var tasks: [ScheduledTask] = []

        guard let contents = try? fileManager.contentsOfDirectory(at: launchAgentsDirectory,
                                                                   includingPropertiesForKeys: nil) else {
            return tasks
        }

        for url in contents where url.pathExtension == "plist" {
            if var task = parsePlist(at: url) {
                let isLoaded = await isRunning(task: task)
                task.status.state = isLoaded ? .enabled : .disabled
                tasks.append(task)
            }
        }

        return tasks
    }

    private func parsePlist(at url: URL) -> ScheduledTask? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        guard let label = plist["Label"] as? String else {
            return nil
        }

        let isExternal: Bool
        let uuid: UUID
        let taskName: String

        if label.hasPrefix("com.macscheduler.task.") {
            isExternal = false
            let uuidString = String(label.dropFirst("com.macscheduler.task.".count))
            guard let parsedUUID = UUID(uuidString: uuidString.uppercased()) else {
                return nil
            }
            uuid = parsedUUID
            taskName = ""
        } else {
            isExternal = true
            uuid = ScheduledTask.uuidFromLabel(label)
            taskName = formatLabelAsName(label)
        }

        var task = ScheduledTask(id: uuid, isExternal: isExternal)
        task.name = taskName
        task.backend = .launchd
        task.externalLabel = isExternal ? label : nil

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
