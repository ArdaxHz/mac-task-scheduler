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
        try await setCronLineEnabled(true, for: task)
    }

    func disable(task: ScheduledTask) async throws {
        try await setCronLineEnabled(false, for: task)
    }

    /// The tag sits on its own line; the cron line it owns is the next one.
    /// Disabled entries are stored as "# <cron line>" (see parseCronLine).
    private func setCronLineEnabled(_ enabled: Bool, for task: ScheduledTask) async throws {
        var currentCrontab = try await getCurrentCrontab()
        guard let tagIndex = currentCrontab.firstIndex(of: task.cronTag),
              tagIndex + 1 < currentCrontab.count else {
            throw SchedulerError.taskNotFound(task.id)
        }
        let line = currentCrontab[tagIndex + 1]
        let isDisabled = line.hasPrefix("# ")
        if enabled && isDisabled {
            currentCrontab[tagIndex + 1] = String(line.dropFirst(2))
        } else if !enabled && !isDisabled {
            currentCrontab[tagIndex + 1] = "# \(line)"
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
            guard let tagIndex = crontab.firstIndex(of: task.cronTag),
                  tagIndex + 1 < crontab.count else { return false }
            return !crontab[tagIndex + 1].hasPrefix("#")
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

            // Tagged entry (created by the app): tag line followed by cron line
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

            // Untagged entry (created outside the app): parse directly
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // Looks like a cron line — try to parse it
                let label = "cron.\(labelFromCronCommand(trimmed))"
                if let task = parseCronLine(trimmed, label: label) {
                    tasks.append(task)
                }
            }

            i += 1
        }

        return tasks
    }

    /// Derive a stable label from a cron command for deterministic UUID generation.
    private func labelFromCronCommand(_ cronLine: String) -> String {
        let components = cronLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard components.count >= 6 else { return "unknown" }
        let command = components.dropFirst(5).joined(separator: " ")
        // Use a short hash-like identifier from the command for a stable label
        let sanitized = command
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_/")).inverted)
            .joined()
        let truncated = String(sanitized.prefix(60))
        return truncated.isEmpty ? "unknown" : truncated
    }

    /// Get the current cron entry for a task as raw text (tag line + cron line).
    func getCurrentCronEntry(for task: ScheduledTask) async -> String? {
        guard let crontab = try? await getCurrentCrontab() else { return nil }
        let tag = task.cronTag

        for i in 0..<crontab.count {
            if crontab[i] == tag, i + 1 < crontab.count {
                return "\(crontab[i])\n\(crontab[i + 1])"
            }
        }
        return nil
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

        // Create temp file with restricted permissions atomically to prevent race condition
        let data = Data(crontabContent.utf8)
        guard FileManager.default.createFile(atPath: tempFile.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw SchedulerError.cronUpdateFailed("Failed to create temp crontab file")
        }
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

    /// Shell-quote a string so it's safe to embed in a cron command line.
    /// Strips null bytes (which can truncate C strings) and newlines (which would inject cron entries).
    private func shellQuote(_ string: String) -> String {
        if string.isEmpty { return "''" }
        let sanitized = string
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Wrap in single quotes, escaping any embedded single quotes
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote an inline script. Multi-line scripts can't live on one cron line,
    /// so they're base64-encoded and decoded at run time (alphabet is shell-safe).
    private func quoteScript(_ script: String) -> String {
        let cleaned = script.replacingOccurrences(of: "\0", with: "")
        guard cleaned.contains("\n") || cleaned.contains("\r") else { return shellQuote(cleaned) }
        return "\"$(echo \(Data(cleaned.utf8).base64EncodedString()) | /usr/bin/base64 -D)\""
    }

    // Matches the output of quoteScript for multi-line scripts
    private static let base64ScriptPattern = try? NSRegularExpression(
        pattern: #"^"\$\(echo ([A-Za-z0-9+/=]+) \| /usr/bin/base64 -D\)"$"#)

    private func generateCronLine(for task: ScheduledTask) -> String {
        guard let schedule = task.trigger.calendarSchedule else {
            return ""
        }

        let cronExpr = CronParser.fromCalendarSchedule(schedule)

        var command: String
        switch task.action.type {
        case .executable:
            if task.action.arguments.isEmpty {
                command = shellQuote(task.action.path)
            } else {
                let quotedArgs = task.action.arguments.map { shellQuote($0) }.joined(separator: " ")
                command = "\(shellQuote(task.action.path)) \(quotedArgs)"
            }
        case .shellScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                command = "/bin/bash -c \(quoteScript(script))"
            } else {
                command = "/bin/bash \(shellQuote(task.action.path))"
            }
        case .appleScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                command = "/usr/bin/osascript -e \(quoteScript(script))"
            } else {
                command = "/usr/bin/osascript \(shellQuote(task.action.path))"
            }
        }

        // Unescaped % is turned into a newline by cron
        command = command.replacingOccurrences(of: "%", with: "\\%")

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

        // Undo cron's % escaping; quoting is handled by ShellWords.split below
        let command = components.dropFirst(5).joined(separator: " ")
            .replacingOccurrences(of: "\\%", with: "%")

        let uuid = ScheduledTask.uuidFromLabel(label)
        var task = ScheduledTask(id: uuid, launchdLabel: label)
        task.name = label
        task.backend = .cron
        task.trigger = TaskTrigger(
            type: .calendar,
            calendarSchedule: CronParser.toCalendarSchedule(cron)
        )
        task.status.state = isDisabled ? .disabled : .enabled

        // Inline script: "<interpreter> <flag> <quoted or base64 script>"
        for (prefix, type) in [("/bin/bash -c ", TaskActionType.shellScript),
                               ("/usr/bin/osascript -e ", TaskActionType.appleScript)]
        where command.hasPrefix(prefix) {
            let quoted = String(command.dropFirst(prefix.count))
            task.action.type = type
            if let match = Self.base64ScriptPattern?.firstMatch(in: quoted, range: NSRange(quoted.startIndex..., in: quoted)),
               let b64Range = Range(match.range(at: 1), in: quoted),
               let data = Data(base64Encoded: String(quoted[b64Range])) {
                task.action.scriptContent = String(decoding: data, as: UTF8.self)
            } else {
                task.action.scriptContent = ShellWords.split(quoted).joined(separator: " ")
            }
            return task
        }

        let parts = ShellWords.split(command)
        guard let first = parts.first else { return nil }
        if first == "/bin/bash" && parts.count == 2 {
            task.action.type = .shellScript
            task.action.path = parts[1]
        } else if first == "/usr/bin/osascript" && parts.count == 2 {
            task.action.type = .appleScript
            task.action.path = parts[1]
        } else {
            task.action.type = .executable
            task.action.path = first
            task.action.arguments = Array(parts.dropFirst())
        }

        return task
    }
}
