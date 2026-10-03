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
    private var allLaunchDirectories: [(url: URL, isUserWritable: Bool, location: TaskLocation)] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), true, .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), true, .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), true, .systemDaemon),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), false, .systemAgent),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), false, .systemDaemon),
        ]
    }

    private init() {
        ensureLaunchAgentsDirectoryExists()
    }

    private func ensureLaunchAgentsDirectoryExists() {
        try? fileManager.createDirectory(at: userLaunchAgentsDirectory,
                                         withIntermediateDirectories: true)
    }

    /// Plist URL for a task in its target location directory.
    private func plistURL(for task: ScheduledTask) -> URL {
        URL(fileURLWithPath: task.location.directory).appendingPathComponent(task.plistFileName)
    }

    /// Default path for new tasks (in user LaunchAgents) — kept for backward compat.
    private func defaultPlistURL(for task: ScheduledTask) -> URL {
        plistURL(for: task)
    }

    /// Resolve the actual plist path: use stored path if available and validated, otherwise construct from label.
    private func resolvedPlistPath(for task: ScheduledTask) -> String {
        if let path = task.plistFilePath, fileManager.fileExists(atPath: path) {
            // Validate that the stored path is within a known launch directory
            let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let isInKnownDirectory = allLaunchDirectories.contains { dir in
                resolvedPath.hasPrefix(dir.url.standardizedFileURL.path + "/")
            }
            if isInKnownDirectory {
                return path
            }
        }
        return plistURL(for: task).path
    }

    // MARK: - Elevated Privilege Helpers

    /// Escape a string for embedding inside an AppleScript `do shell script "..."` context.
    /// AppleScript string literals only recognise \\ and \" (plus \n \r \t); `\$` etc. are syntax errors.
    /// Shell metacharacters are already neutralised by shellQuote() in the script itself.
    private func escapeForAppleScript(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    /// Run a shell command with admin privileges via osascript.
    /// The script string must already be properly quoted/escaped for the shell.
    private func executeElevated(script: String) async throws {
        let escaped = escapeForAppleScript(script)
        let result = try await shellExecutor.execute(
            command: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
        if result.exitCode != 0 {
            throw SchedulerError.plistCreationFailed(result.standardError)
        }
    }

    /// Shell command (to run as root) that writes `content` to `path` as a root-owned 0644 file.
    /// The content is embedded in the command itself: a user-writable temp file could be
    /// swapped by another process while the admin prompt is open. Base64 is shell/AppleScript-safe.
    private func elevatedWriteCommand(content: String, to path: String) -> String {
        let encoded = Data(content.utf8).base64EncodedString()
        let quotedPath = shellQuote(path)
        return "echo \(encoded) | /usr/bin/base64 -D > \(quotedPath) && chmod 644 \(quotedPath) && chown root:wheel \(quotedPath)"
    }

    /// Write a file to a path, using elevated privileges if needed.
    private func writeFile(content: String, to path: String, elevated: Bool) async throws {
        if elevated {
            try await executeElevated(script: elevatedWriteCommand(content: content, to: path))
        } else {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Delete a file, using elevated privileges if needed.
    private func deleteFile(at path: String, elevated: Bool) async throws {
        if elevated {
            try await executeElevated(script: "rm -f \(shellQuote(path))")
        } else {
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Run launchctl load/unload, with sudo if elevated.
    private func launchctl(_ action: String, path: String, elevated: Bool) async throws -> ShellResult {
        // Validate action to prevent injection
        guard action == "load" || action == "unload" else {
            throw SchedulerError.commandExecutionFailed("Invalid launchctl action: \(action)")
        }
        if elevated {
            let quotedPath = shellQuote(path)
            let script = "launchctl \(action) \(quotedPath)"
            let escaped = escapeForAppleScript(script)
            let result = try await shellExecutor.execute(
                command: "/usr/bin/osascript",
                arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            )
            return result
        } else {
            return try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: [action, path]
            )
        }
    }

    func install(task: ScheduledTask) async throws {
        let plistContent = plistGenerator.generate(for: task)
        let plistPath = plistURL(for: task).path
        let elevated = task.location.requiresElevation

        do {
            try await writeFile(content: plistContent, to: plistPath, elevated: elevated)
        } catch {
            throw SchedulerError.plistCreationFailed(error.localizedDescription)
        }
    }

    func uninstall(task: ScheduledTask) async throws {
        let isCurrentlyLoaded = await isLoaded(label: task.launchdLabel)
        if isCurrentlyLoaded {
            try await disable(task: task)
        }

        let path = resolvedPlistPath(for: task)
        if fileManager.fileExists(atPath: path) {
            do {
                try await deleteFile(at: path, elevated: task.location.requiresElevation)
            } catch {
                throw SchedulerError.fileSystemError(error.localizedDescription)
            }
        }
    }

    func enable(task: ScheduledTask) async throws {
        let path = resolvedPlistPath(for: task)
        let elevated = loadNeedsRoot(task.location)

        guard fileManager.fileExists(atPath: path) else {
            try await install(task: task)
            let newPath = plistURL(for: task).path
            let result = try await launchctl("load", path: newPath, elevated: elevated)
            if result.exitCode != 0 && !result.standardError.contains("already loaded") {
                throw SchedulerError.plistLoadFailed(result.standardError)
            }
            return
        }

        let result = try await launchctl("load", path: path, elevated: elevated)
        if result.exitCode != 0 && !result.standardError.contains("already loaded") {
            throw SchedulerError.plistLoadFailed(result.standardError)
        }
    }

    func disable(task: ScheduledTask) async throws {
        let path = resolvedPlistPath(for: task)
        let elevated = loadNeedsRoot(task.location)

        guard fileManager.fileExists(atPath: path) else {
            return
        }

        let result = try await launchctl("unload", path: path, elevated: elevated)
        if result.exitCode != 0 && !result.standardError.contains("Could not find") {
            throw SchedulerError.plistUnloadFailed(result.standardError)
        }
    }

    /// Daemons live in the system domain and must be (un)loaded as root. Agents — including
    /// those in /Library/LaunchAgents — are loaded as the user; loading them as root would
    /// register them in the system domain as root jobs.
    private func loadNeedsRoot(_ location: TaskLocation) -> Bool {
        location == .systemDaemon
    }

    /// launchctl service target for a label, e.g. "system/com.x" or "gui/501/com.x".
    private func serviceTarget(label: String, location: TaskLocation) -> String {
        location == .systemDaemon ? "system/\(label)" : "gui/\(getuid())/\(label)"
    }

    /// One step of an update. `.either` steps run as root when adjacent to root work
    /// (so they share its prompt) and as the user otherwise.
    private enum UpdateStep {
        case root(String)
        case user(() async throws -> Void)
        case either(String, () async throws -> Void)
    }

    /// Decide which steps run as root: true = root, false = user, nil = either.
    /// An "either" step runs as root if its nearest decided neighbour on either side is root.
    static func resolveRoot(_ kinds: [Bool?]) -> [Bool] {
        kinds.indices.map { i in
            if let k = kinds[i] { return k }
            let prev = kinds[..<i].reversed().lazy.compactMap { $0 }.first
            let next = kinds[(i + 1)...].lazy.compactMap { $0 }.first
            return prev == true || next == true
        }
    }

    /// Run steps in order, batching consecutive root steps into a single admin prompt.
    private func run(_ steps: [UpdateStep]) async throws {
        let asRoot = Self.resolveRoot(steps.map { step -> Bool? in
            switch step { case .root: return true; case .user: return false; case .either: return nil }
        })
        var rootBatch: [String] = []
        func flush() async throws {
            guard !rootBatch.isEmpty else { return }
            try await executeElevated(script: rootBatch.joined(separator: " && "))
            rootBatch = []
        }
        for (step, root) in zip(steps, asRoot) {
            switch step {
            case .root(let cmd):
                rootBatch.append(cmd)
            case .either(let cmd, let work):
                if root {
                    rootBatch.append(cmd)
                } else {
                    try await flush()
                    try await work()
                }
            case .user(let work):
                try await flush()
                try await work()
            }
        }
        try await flush()
    }

    /// Update a task without ever leaving it with no plist: the new file is written first,
    /// the old job is unloaded by label (so overwriting the same path is safe), the old file
    /// is removed only if the path changed, then the new job is loaded. All privileged steps
    /// share one admin prompt. Keys the app doesn't model are preserved from the old plist.
    func updateTask(oldTask: ScheduledTask, newTask: ScheduledTask) async throws {
        let oldPath = resolvedPlistPath(for: oldTask)
        let newPath = plistURL(for: newTask).path
        let oldExists = fileManager.fileExists(atPath: oldPath)
        let content = plistContent(for: newTask, mergingWith: oldExists ? oldPath : nil)
        let newFileNeedsRoot = newTask.location.requiresElevation
        let oldFileNeedsRoot = oldTask.location.requiresElevation
        let oldTarget = serviceTarget(label: oldTask.launchdLabel, location: oldTask.location)
        let newDaemon = loadNeedsRoot(newTask.location)

        var steps: [UpdateStep] = []

        // 1. Write the new plist
        if newFileNeedsRoot {
            steps.append(.root(elevatedWriteCommand(content: content, to: newPath)))
        } else {
            steps.append(.user { try content.write(toFile: newPath, atomically: true, encoding: .utf8) })
        }

        // 2. Unload the old job by label (failure = it wasn't loaded)
        let bootout = "(/bin/launchctl bootout \(shellQuote(oldTarget)) 2>/dev/null || true)"
        let userBootout: () async throws -> Void = {
            _ = try? await self.shellExecutor.execute(command: "/bin/launchctl", arguments: ["bootout", oldTarget])
        }
        steps.append(loadNeedsRoot(oldTask.location) ? .root(bootout) : .either(bootout, userBootout))

        // 3. Remove the old plist if it lived elsewhere (label or location changed)
        if oldExists && oldPath != newPath {
            let rm = "rm -f \(shellQuote(oldPath))"
            steps.append(oldFileNeedsRoot ? .root(rm) : .either(rm) { try self.fileManager.removeItem(atPath: oldPath) })
        }

        // 4. Load the new job (and unload again if it should stay disabled)
        if newDaemon {
            steps.append(.root("/bin/launchctl load \(shellQuote(newPath))"))
            if !newTask.isEnabled {
                steps.append(.root("(/bin/launchctl unload \(shellQuote(newPath)) || true)"))
            }
        } else {
            steps.append(.user {
                // If step 2 ran inside a root batch, make sure the old agent is gone from our domain too
                if !self.loadNeedsRoot(oldTask.location) { try await userBootout() }
                let result = try await self.launchctl("load", path: newPath, elevated: false)
                if result.exitCode != 0 && !result.standardError.contains("already loaded") {
                    throw SchedulerError.plistLoadFailed(result.standardError)
                }
                if !newTask.isEnabled {
                    _ = try? await self.launchctl("unload", path: newPath, elevated: false)
                }
            })
        }

        try await run(steps)
    }

    /// Keys this app models. Everything else in an existing plist (WatchPaths, Sockets,
    /// ThrottleInterval, ...) is carried over unchanged when a task is edited.
    private static let managedPlistKeys: Set<String> = [
        "Label", "Program", "ProgramArguments", "WorkingDirectory", "EnvironmentVariables",
        "StartCalendarInterval", "StartInterval", "RunAtLoad", "KeepAlive",
        "StandardOutPath", "StandardErrorPath", "UserName",
        "MacSchedulerName", "MacSchedulerDescription",
    ]

    /// Generate the plist for `task`, merged over the existing plist at `existingPath`.
    func plistContent(for task: ScheduledTask, mergingWith existingPath: String?) -> String {
        let generated = plistGenerator.generate(for: task)
        guard let path = existingPath,
              let oldData = fileManager.contents(atPath: path), oldData.count < 1_048_576,
              let old = try? PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any],
              let new = try? PropertyListSerialization.propertyList(from: Data(generated.utf8), format: nil) as? [String: Any]
        else { return generated }

        var merged = old.filter { !Self.managedPlistKeys.contains($0.key) }
        merged.merge(new) { _, generatedValue in generatedValue }

        // Multiple calendar entries: the editor only shows the first. Keep them all unless it changed.
        // (Editor turns an absent Minute/Hour into 0, so compare with that normalisation.)
        func normalized(_ d: [String: Any]) -> NSDictionary {
            var d = d
            d["Minute"] = d["Minute"] ?? 0
            d["Hour"] = d["Hour"] ?? 0
            return d as NSDictionary
        }
        if let oldEntries = old["StartCalendarInterval"] as? [[String: Any]], oldEntries.count > 1,
           let newEntry = new["StartCalendarInterval"] as? [String: Any],
           normalized(oldEntries[0]).isEqual(normalized(newEntry)) {
            merged["StartCalendarInterval"] = oldEntries
        }

        // Conditional KeepAlive (a dict) is shown as "on" — keep the conditions while it stays on
        if old["KeepAlive"] is [String: Any], new["KeepAlive"] as? Bool == true {
            merged["KeepAlive"] = old["KeepAlive"]
        }

        guard let data = try? PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0) else {
            return generated
        }
        return String(decoding: data, as: UTF8.self)
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
                // Exit 126 = permission denied. Try chmod +x and retry directly
                // instead of wrapping in a shell, which introduces shell interpretation.
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: task.action.path)
                result = try await shellExecutor.execute(
                    command: task.action.path,
                    arguments: task.action.arguments,
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
            if result.exitCode == 0 { return true }
            // System daemons (and agents loaded as root) live in the system domain,
            // which `launchctl list` as the user can't see
            let system = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["print", "system/\(label)"]
            )
            return system.exitCode == 0
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

    /// Info extracted from `launchctl print` for a specific service.
    struct ServicePrintInfo {
        let runs: Int
        let lastExitCode: Int32
        let pid: Int?
    }

    /// Read run count, last exit code, and PID from launchctl print.
    func getLaunchdInfo(for task: ScheduledTask) async -> ServicePrintInfo? {
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["print", serviceTarget(label: task.launchdLabel, location: task.location)],
                timeout: 5.0
            )
            guard result.exitCode == 0 else { return nil }

            var runs = 0
            var lastExit: Int32 = 0
            var pid: Int?

            for line in result.standardOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("runs = ") {
                    runs = Int(trimmed.dropFirst("runs = ".count)) ?? 0
                } else if trimmed.hasPrefix("last exit code = ") {
                    // Format: "last exit code = 0" or "last exit code = (never exited)"
                    let value = String(trimmed.dropFirst("last exit code = ".count))
                    if let code = Int32(value) {
                        lastExit = code
                    }
                } else if trimmed.hasPrefix("pid = ") {
                    pid = Int(trimmed.dropFirst("pid = ".count))
                }
            }
            return ServicePrintInfo(runs: runs, lastExitCode: lastExit, pid: pid)
        } catch {
            return nil
        }
    }

    /// Get process start time from PID using sysctl (avoids spawning `ps`).
    func getProcessStartTime(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Info about a loaded launchd service from `launchctl list`.
    struct LoadedServiceInfo {
        let pid: Int?          // nil if not currently running
        let lastExitStatus: Int32
    }

    /// Get all loaded launchd labels with PID and exit status.
    /// `launchctl list` (run as the user) only sees the gui/<uid> domain, so system
    /// daemons are merged in from `launchctl print system`.
    func getAllLoadedServices() async -> [String: LoadedServiceInfo] {
        async let system = getSystemDomainServices()
        let user = await getUserDomainServices()
        return await system.merging(user) { _, userInfo in userInfo }
    }

    /// Parse the `services = { pid status label }` block of `launchctl print system`.
    private func getSystemDomainServices() async -> [String: LoadedServiceInfo] {
        guard let result = try? await shellExecutor.execute(
            command: "/bin/launchctl", arguments: ["print", "system"], timeout: 10.0
        ), result.exitCode == 0 else { return [:] }

        var services: [String: LoadedServiceInfo] = [:]
        var inServices = false
        for line in result.standardOutput.components(separatedBy: "\n") {
            if line == "\tservices = {" { inServices = true; continue }
            guard inServices else { continue }
            if line == "\t}" { break }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3 else { continue }
            let pid = Int(parts[0]).flatMap { $0 > 0 ? $0 : nil }
            services[String(parts[2])] = LoadedServiceInfo(pid: pid, lastExitStatus: Int32(parts[1]) ?? 0)
        }
        return services
    }

    private func getUserDomainServices() async -> [String: LoadedServiceInfo] {
        do {
            let result = try await shellExecutor.execute(
                command: "/bin/launchctl",
                arguments: ["list"],
                timeout: 10.0
            )
            guard result.exitCode == 0 else { return [:] }
            var services: [String: LoadedServiceInfo] = [:]
            for line in result.standardOutput.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 3 {
                    let pidStr = parts[0]
                    let statusStr = parts[1]
                    let label = parts[2]
                    let pid = pidStr == "-" ? nil : Int(pidStr)
                    let exitStatus = Int32(statusStr) ?? 0
                    services[label] = LoadedServiceInfo(pid: pid, lastExitStatus: exitStatus)
                }
            }
            return services
        } catch {
            return [:]
        }
    }

    /// Convenience: just the labels (for backward compat).
    func getAllLoadedLabels() async -> Set<String> {
        Set(await getAllLoadedServices().keys)
    }

    /// Discover tasks from all launchd directories.
    func discoverTasks() async throws -> [ScheduledTask] {
        let loadedServices = await getAllLoadedServices()
        var tasks: [ScheduledTask] = []

        for dir in allLaunchDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(at: dir.url,
                                                                       includingPropertiesForKeys: nil) else {
                continue
            }

            for url in contents where url.pathExtension == "plist" {
                if var task = parsePlist(at: url, isUserWritable: dir.isUserWritable) {
                    if let info = loadedServices[task.launchdLabel] {
                        if let pid = info.pid {
                            task.status.state = .running
                            // sysctl, no subprocess — cheap enough to do for every running job
                            if let start = getProcessStartTime(pid: pid) {
                                task.status.processStartTime = start
                                task.status.lastRun = start
                            }
                        } else if info.lastExitStatus != 0 {
                            task.status.state = .error
                            task.status.lastExitStatus = info.lastExitStatus
                        } else {
                            task.status.state = .enabled
                        }
                    } else {
                        task.status.state = .disabled
                    }
                    task.plistFilePath = url.path
                    task.location = dir.location
                    tasks.append(task)
                }
            }
        }

        return tasks
    }

    private func parsePlist(at url: URL, isUserWritable: Bool = true) -> ScheduledTask? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parsePlistData(data, isUserWritable: isUserWritable)
    }

    /// Parse raw plist data into a ScheduledTask. Used by parsePlist(at:) and for revert-from-snapshot.
    func parsePlistData(_ data: Data, isUserWritable: Bool = true) -> ScheduledTask? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
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

        if let userName = plist["UserName"] as? String {
            task.userName = userName
        }

        if let program = plist["Program"] as? String {
            task.action.path = program
            task.action.type = .executable
        }

        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            task.action.path = args[0]
            task.action.arguments = Array(args.dropFirst())

            // Match the binary name exactly — hasSuffix("sh") would also match /usr/bin/ssh
            let binaryName = (args[0] as NSString).lastPathComponent
            if ["bash", "sh", "zsh", "fish", "dash"].contains(binaryName) {
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
                // Only the first entry is modelled; updateTask keeps the rest (see plistContent)
                task.trigger = TaskTrigger(type: .calendar, calendarSchedule: schedule)
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
    /// Also strips null bytes which can truncate C strings and split quoted arguments.
    private func shellQuote(_ string: String) -> String {
        if string.isEmpty { return "''" }
        let sanitized = string.replacingOccurrences(of: "\0", with: "")
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
