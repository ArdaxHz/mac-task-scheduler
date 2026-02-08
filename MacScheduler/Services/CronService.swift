//
//  CronService.swift
//  MacScheduler
//
//  Service for managing tasks via crontab.
//

import Foundation

class CronService: SchedulerService {
    static let shared = CronService()
    let backend: SchedulerBackend = .cron

    private let shellExecutor = ShellExecutor.shared
    private let tagPrefix = "# CronTask:"

    private init() {}

    func install(task: ScheduledTask) async throws {
        let errors = task.validate()
        if !errors.isEmpty {
            throw SchedulerError.invalidTask(errors.joined(separator: "; "))
        }

        guard task.trigger.type == .calendar else {
            throw SchedulerError.invalidTask("Cron only supports calendar-based triggers")
        }

        var currentCrontab = try await getCurrentCrontab()

        currentCrontab = removeCronEntry(for: task, from: currentCrontab)

        let cronLine = generateCronLine(for: task)
        currentCrontab.append(cronLine)

        try await setCrontab(currentCrontab)
    }

    func uninstall(task: ScheduledTask) async throws {
        var currentCrontab = try await getCurrentCrontab()
        currentCrontab = removeCronEntry(for: task, from: currentCrontab)
        try await setCrontab(currentCrontab)
    }

    func enable(task: ScheduledTask) async throws {
        var currentCrontab = try await getCurrentCrontab()
        let tag = task.cronTag

        currentCrontab = currentCrontab.map { line in
            if line.contains(tag) && line.hasPrefix("#") && !line.hasPrefix(tagPrefix) {
                var uncommented = line
                if let range = uncommented.range(of: "# ") {
                    uncommented.removeSubrange(range)
                }
                return uncommented
            }
            return line
        }

        try await setCrontab(currentCrontab)
    }

    func disable(task: ScheduledTask) async throws {
        var currentCrontab = try await getCurrentCrontab()
        let tag = task.cronTag

        currentCrontab = currentCrontab.map { line in
            if line.contains(tag) && !line.hasPrefix("#") {
                return "# \(line)"
            }
            return line
        }

        try await setCrontab(currentCrontab)
    }

    func runNow(task: ScheduledTask) async throws -> TaskExecutionResult {
        let startTime = Date()

        let result: ShellResult
        switch task.action.type {
        case .executable:
            result = try await shellExecutor.execute(
                command: task.action.path,
                arguments: task.action.arguments,
                workingDirectory: task.action.workingDirectory,
                environment: task.action.environmentVariables
            )
        case .shellScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                result = try await shellExecutor.executeScript(
                    script,
                    shell: "/bin/bash",
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
            } else {
                result = try await shellExecutor.execute(
                    command: "/bin/bash",
                    arguments: [task.action.path],
                    workingDirectory: task.action.workingDirectory,
                    environment: task.action.environmentVariables
                )
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
        do {
            let crontab = try await getCurrentCrontab()
            let tag = task.cronTag
            return crontab.contains { $0.contains(tag) }
        } catch {
            return false
        }
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        do {
            let crontab = try await getCurrentCrontab()
            let tag = task.cronTag
            return crontab.contains { line in
                line.contains(tag) && !line.hasPrefix("#")
            }
        } catch {
            return false
        }
    }

    func discoverTasks() async throws -> [ScheduledTask] {
        let crontab = try await getCurrentCrontab()
        var tasks: [ScheduledTask] = []

        var i = 0
        while i < crontab.count {
            let line = crontab[i]

            if line.hasPrefix(tagPrefix) {
                let label = String(line.dropFirst(tagPrefix.count))
                if i + 1 < crontab.count {
                    let cronLine = crontab[i + 1]
                    if let task = parseCronLine(cronLine, label: label) {
                        tasks.append(task)
                    }
                    i += 2
                    continue
                }
            }

            i += 1
        }

        return tasks
    }

    private func getCurrentCrontab() async throws -> [String] {
        let result = try await shellExecutor.execute(
            command: "/usr/bin/crontab",
            arguments: ["-l"]
        )

        if result.exitCode != 0 && result.standardError.contains("no crontab") {
            return []
        }

        if result.exitCode != 0 {
            throw SchedulerError.cronUpdateFailed(result.standardError)
        }

        return result.standardOutput.components(separatedBy: "\n")
    }

    private func setCrontab(_ lines: [String]) async throws {
        let crontabContent = lines.joined(separator: "\n")

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".crontab")

        try crontabContent.write(to: tempFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let result = try await shellExecutor.execute(
            command: "/usr/bin/crontab",
            arguments: [tempFile.path]
        )

        if result.exitCode != 0 {
            throw SchedulerError.cronUpdateFailed(result.standardError)
        }
    }

    private func removeCronEntry(for task: ScheduledTask, from crontab: [String]) -> [String] {
        let tag = task.cronTag
        var result: [String] = []
        var skipNext = false

        for line in crontab {
            if skipNext {
                skipNext = false
                continue
            }

            if line == tag {
                skipNext = true
                continue
            }

            result.append(line)
        }

        return result
    }

    private func generateCronLine(for task: ScheduledTask) -> String {
        guard let schedule = task.trigger.calendarSchedule else {
            return ""
        }

        let cronExpr = CronParser.fromCalendarSchedule(schedule)

        var command: String
        switch task.action.type {
        case .executable:
            if task.action.arguments.isEmpty {
                command = task.action.path
            } else {
                command = "\(task.action.path) \(task.action.arguments.joined(separator: " "))"
            }
        case .shellScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                command = "/bin/bash -c '\(script.replacingOccurrences(of: "'", with: "'\\''"))'"
            } else {
                command = "/bin/bash \(task.action.path)"
            }
        case .appleScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                command = "/usr/bin/osascript -e '\(script.replacingOccurrences(of: "'", with: "'\\''"))'"
            } else {
                command = "/usr/bin/osascript \(task.action.path)"
            }
        }

        let tag = task.cronTag
        return "\(tag)\n\(cronExpr.expression) \(command)"
    }

    private func parseCronLine(_ line: String, label: String) -> ScheduledTask? {
        var workingLine = line
        let isDisabled = line.hasPrefix("# ")
        if isDisabled {
            workingLine = String(line.dropFirst(2))
        }

        let components = workingLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard components.count >= 6 else {
            return nil
        }

        let cronExpr = "\(components[0]) \(components[1]) \(components[2]) \(components[3]) \(components[4])"
        guard let cron = CronParser.parse(cronExpr) else {
            return nil
        }

        let command = components.dropFirst(5).joined(separator: " ")

        let uuid = ScheduledTask.uuidFromLabel(label)
        var task = ScheduledTask(id: uuid, launchdLabel: label)
        task.name = label
        task.backend = .cron
        task.trigger = TaskTrigger(
            type: .calendar,
            calendarSchedule: CronParser.toCalendarSchedule(cron)
        )
        task.status.state = isDisabled ? .disabled : .enabled

        if command.hasPrefix("/bin/bash -c") {
            task.action.type = .shellScript
            if let scriptRange = command.range(of: "-c '") {
                let script = String(command[scriptRange.upperBound...].dropLast())
                task.action.scriptContent = script
            }
        } else if command.hasPrefix("/usr/bin/osascript -e") {
            task.action.type = .appleScript
            if let scriptRange = command.range(of: "-e '") {
                let script = String(command[scriptRange.upperBound...].dropLast())
                task.action.scriptContent = script
            }
        } else {
            task.action.type = .executable
            let parts = command.components(separatedBy: " ")
            task.action.path = parts[0]
            task.action.arguments = Array(parts.dropFirst())
        }

        return task
    }
}
