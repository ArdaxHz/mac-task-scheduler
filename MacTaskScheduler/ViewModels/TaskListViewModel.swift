//
//  TaskListViewModel.swift
//  MacScheduler
//
//  ViewModel for managing the list of scheduled tasks.
//  Fully stateless: reads all task data from live LaunchAgents/cron files.
//

import Foundation
import SwiftUI

@MainActor
class TaskListViewModel: ObservableObject {
    @Published var tasks: [ScheduledTask] = []
    @Published var selectedTask: ScheduledTask?
    @Published var isLoading = false
    private var loadingCount = 0
    private var activeActionIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var searchText = ""
    @Published var filterBackend: SchedulerBackend?
    @Published var filterStates: Set<TaskState> = []
    @Published var filterTriggerType: TriggerType?
    @Published var filterLastRun: LastRunFilter = .all
    @Published var filterOwnership: OwnershipFilter = .all
    @Published var filterLocation: LocationFilter = .all
    @Published var isDockerOffline: Bool = false

    enum LocationFilter: String, CaseIterable {
        case all = "All"
        case userAgent = "User Agent"
        case systemAgent = "System Agent"
        case systemDaemon = "System Daemon"
    }

    enum LastRunFilter: String, CaseIterable {
        case all = "All"
        case hasRun = "Has Run"
        case neverRun = "Never Run"
    }

    enum OwnershipFilter: String, CaseIterable {
        case all = "All"
        case editable = "Editable"
        case readOnly = "Read-Only"
    }

    private let historyService = TaskHistoryService.shared
    private let versionService = TaskVersionService.shared

    var filteredTasks: [ScheduledTask] {
        var result = tasks

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.launchdLabel.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let backend = filterBackend {
            result = result.filter { $0.backend == backend }
        }

        if !filterStates.isEmpty {
            result = result.filter { filterStates.contains($0.status.state) }
        }

        if let triggerType = filterTriggerType {
            result = result.filter { $0.trigger.type == triggerType }
        }

        switch filterLastRun {
        case .all: break
        case .hasRun: result = result.filter { $0.status.lastRun != nil }
        case .neverRun: result = result.filter { $0.status.lastRun == nil }
        }

        switch filterOwnership {
        case .all: break
        case .editable: result = result.filter { !$0.isReadOnly }
        case .readOnly: result = result.filter { $0.isReadOnly }
        }

        switch filterLocation {
        case .all: break
        case .userAgent: result = result.filter { $0.location == .userAgent }
        case .systemAgent: result = result.filter { $0.location == .systemAgent }
        case .systemDaemon: result = result.filter { $0.location == .systemDaemon }
        }

        return result
    }

    /// Pre-computed status counts — avoids re-filtering tasks per TaskState on every render.
    var statusCounts: [TaskState: Int] {
        var counts: [TaskState: Int] = [:]
        for task in tasks {
            counts[task.status.state, default: 0] += 1
        }
        return counts
    }


    init() {
        // Discovery is triggered by the view via .task { } modifier
        // to ensure SwiftUI has subscribed to @Published before data loads.
    }

    private func beginLoading() {
        loadingCount += 1
        isLoading = true
    }

    private func endLoading() {
        loadingCount = max(0, loadingCount - 1)
        if loadingCount == 0 {
            isLoading = false
        }
    }

    /// Discover all tasks from live LaunchAgents and cron files.
    func discoverAllTasks() async {
        beginLoading()
        defer { endLoading() }
        let log = AppLogger.shared

        do {
            let launchdService = LaunchdService.shared
            let cronService = CronService.shared

            log.info("Starting task discovery")
            // Fetch all backends in parallel so a slow Docker/VM CLI only costs one timeout
            async let launchdResult = launchdService.discoverTasks()
            async let cronResult = cronService.discoverTasks()

            // Docker discovery is non-blocking — failure should not affect other backends
            async let dockerResult: [ScheduledTask] = {
                do {
                    return try await DockerService.shared.discoverTasks()
                } catch {
                    log.debug("Docker discovery skipped: \(error.localizedDescription)")
                    return []
                }
            }()

            // VM discovery — each backend is non-blocking, failures silently ignored
            async let vmResult: [ScheduledTask] = withTaskGroup(of: [ScheduledTask].self) { group in
                let vmServices: [any SchedulerService] = [
                    ParallelsService.shared,
                    VirtualBoxService.shared,
                    UTMService.shared,
                    VMwareFusionService.shared
                ]
                for vmService in vmServices {
                    // Tool may not be installed — ignore errors
                    group.addTask { (try? await vmService.discoverTasks()) ?? [] }
                }
                return await group.reduce(into: []) { $0.append(contentsOf: $1) }
            }

            let (launchdTasks, cronTasks) = try await (launchdResult, cronResult)
            log.info("Discovered \(launchdTasks.count) launchd tasks, \(cronTasks.count) cron tasks")
            let dockerTasks = await dockerResult
            if !dockerTasks.isEmpty {
                log.info("Discovered \(dockerTasks.count) Docker containers")
            }
            let vmTasks = await vmResult

            // Dedup by task ID (deterministic UUID from label) — prefer user-writable over read-only
            var tasksById: [UUID: ScheduledTask] = [:]
            tasksById.reserveCapacity(launchdTasks.count + cronTasks.count + dockerTasks.count + vmTasks.count)
            for task in launchdTasks {
                if let existing = tasksById[task.id] {
                    if !task.isReadOnly && existing.isReadOnly {
                        tasksById[task.id] = task
                    }
                } else {
                    tasksById[task.id] = task
                }
            }
            for task in cronTasks {
                if tasksById[task.id] == nil {
                    tasksById[task.id] = task
                }
            }
            for task in dockerTasks {
                if tasksById[task.id] == nil {
                    tasksById[task.id] = task
                }
            }
            for task in vmTasks {
                if tasksById[task.id] == nil {
                    tasksById[task.id] = task
                }
            }

            var allTasks = Array(tasksById.values)

            let launchdIndices = allTasks.indices.filter { allTasks[$0].backend == .launchd }

            // Enrich launchd tasks: file mtimes (cheap, synchronous)
            for i in launchdIndices {
                if let lastRun = launchdService.getLastRunTime(for: allTasks[i]) {
                    allTasks[i].status.lastRun = lastRun
                }
            }

            // Fetch launchctl print info in parallel for loaded (enabled/running/error) tasks
            let loadedIndices = launchdIndices.filter {
                let state = allTasks[$0].status.state
                return state == .enabled || state == .running || state == .error
            }
            if !loadedIndices.isEmpty {
                let infos: [(Int, LaunchdService.ServicePrintInfo?)] = await withTaskGroup(of: (Int, LaunchdService.ServicePrintInfo?).self) { group in
                    for i in loadedIndices {
                        let task = allTasks[i]
                        group.addTask {
                            let info = await launchdService.getLaunchdInfo(for: task)
                            return (i, info)
                        }
                    }
                    var results: [(Int, LaunchdService.ServicePrintInfo?)] = []
                    results.reserveCapacity(loadedIndices.count)
                    for await result in group {
                        results.append(result)
                    }
                    return results
                }
                for (i, info) in infos {
                    if let info = info {
                        allTasks[i].status.runCount = info.runs

                        if let pid = info.pid {
                            // Running task: store process start time
                            if let startTime = launchdService.getProcessStartTime(pid: pid) {
                                allTasks[i].status.processStartTime = startTime
                                allTasks[i].status.lastRun = startTime
                            }
                        }

                        // Store last exit code for error tasks
                        if allTasks[i].status.state == .error {
                            allTasks[i].status.lastExitStatus = info.lastExitCode
                        }
                    }
                }
            }

            // Merge app execution history as fallback for last run time
            for i in allTasks.indices {
                let taskHistory = await historyService.getHistory(for: allTasks[i].id)
                if let latestRun = taskHistory.first {
                    if allTasks[i].status.lastRun == nil || latestRun.endTime > (allTasks[i].status.lastRun ?? .distantPast) {
                        allTasks[i].status.lastRun = latestRun.endTime
                    }
                    if allTasks[i].status.lastResult == nil {
                        allTasks[i].status.lastResult = latestRun
                    }
                    if allTasks[i].status.runCount == 0 {
                        allTasks[i].status.runCount = taskHistory.count
                    }
                    allTasks[i].status.failureCount = taskHistory.filter { !$0.success }.count
                }

                // For tasks with no app-recorded lastResult, synthesize one from log files
                if allTasks[i].status.lastResult == nil, let lastRun = allTasks[i].status.lastRun {
                    let stdout = Self.readLogFile(allTasks[i].standardOutPath)
                    let stderr = Self.readLogFile(allTasks[i].standardErrorPath)
                    if stdout != nil || stderr != nil {
                        let exitCode = allTasks[i].status.lastExitStatus ?? 0
                        allTasks[i].status.lastResult = TaskExecutionResult(
                            taskId: allTasks[i].id,
                            startTime: lastRun,
                            endTime: lastRun,
                            exitCode: exitCode,
                            standardOutput: stdout ?? "",
                            standardError: stderr ?? ""
                        )
                    }
                }
            }

            allTasks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Set Docker offline flag and tasks together so the banner and
            // cached containers appear in the same render pass.
            isDockerOffline = !DockerService.shared.isDockerOnline
            log.info("Total tasks loaded: \(allTasks.count)")
            tasks = allTasks

            // Update selected task if it still exists
            if let selected = selectedTask,
               let updated = tasks.first(where: { $0.launchdLabel == selected.launchdLabel }) {
                selectedTask = updated
            } else if selectedTask != nil {
                selectedTask = nil
            }
        } catch {
            log.error("Task discovery failed: \(error.localizedDescription)")
            showError(message: "Failed to discover tasks: \(error.localizedDescription)")
        }
    }

    func addTask(_ task: ScheduledTask) async {
        beginLoading()
        defer { endLoading() }
        AppLogger.shared.info("Adding task: \(task.launchdLabel) (backend: \(task.backend.rawValue))")

        do {
            if task.backend == .docker {
                // Docker: just install (docker run -d), no separate enable step
                try await DockerService.shared.install(task: task)
            } else {
                let service = SchedulerServiceFactory.service(for: task.backend)
                try await service.install(task: task)

                // Always load into launchd to register the daemon
                try await service.enable(task: task)

                // If user wants it disabled, unload after registering
                if !task.isEnabled {
                    try await service.disable(task: task)
                }
            }

            // Re-discover to pick up the new task from live files
            await discoverAllTasks()

            // Select the newly created task
            selectedTask = tasks.first { $0.launchdLabel == task.launchdLabel }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func updateTask(_ task: ScheduledTask) async {
        beginLoading()
        defer { endLoading() }
        AppLogger.shared.info("Updating task: \(task.launchdLabel)")

        guard let oldTask = tasks.first(where: { $0.id == task.id }) else {
            showError(message: "Task not found")
            return
        }

        // Snapshot before edit — read content synchronously for launchd (fire-and-forget),
        // fall back to async for cron (must complete before uninstall erases cron entry)
        if let snapshotContent = readTaskContent(oldTask) {
            let label = oldTask.launchdLabel
            let name = oldTask.name
            let backend = oldTask.backend.rawValue
            let newLabel = task.launchdLabel != oldTask.launchdLabel ? task.launchdLabel : nil
            let location = oldTask.location
            Task {
                await versionService.saveSnapshotWithContent(
                    snapshotContent, label: label, name: name,
                    reason: .beforeEdit, backend: backend, newLabel: newLabel, location: location
                )
            }
        } else if oldTask.backend == .cron {
            await versionService.saveSnapshot(
                for: oldTask, reason: .beforeEdit,
                newLabel: task.launchdLabel != oldTask.launchdLabel ? task.launchdLabel : nil
            )
        }

        do {
            if task.backend == .docker {
                // Docker-specific update path
                try await updateDockerContainer(oldTask: oldTask, newTask: task)
            } else if task.backend == .launchd {
                let launchdService = LaunchdService.shared
                try await launchdService.updateTask(oldTask: oldTask, newTask: task)
            } else {
                let service = SchedulerServiceFactory.service(for: task.backend)

                if oldTask.backend != task.backend {
                    let oldService = SchedulerServiceFactory.service(for: oldTask.backend)
                    try await oldService.uninstall(task: oldTask)
                } else {
                    try await service.uninstall(task: oldTask)
                }

                try await service.install(task: task)
                if task.isEnabled {
                    try await service.enable(task: task)
                }
            }

            // Re-discover to reflect changes from live files
            await discoverAllTasks()

            // Select the updated task
            selectedTask = tasks.first { $0.launchdLabel == task.launchdLabel }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    /// Docker-specific update: restart policy only → docker update, otherwise → recreate.
    private func updateDockerContainer(oldTask: ScheduledTask, newTask: ScheduledTask) async throws {
        let docker = DockerService.shared
        guard let oldInfo = oldTask.containerInfo, let newInfo = newTask.containerInfo else {
            throw SchedulerError.invalidTask("Missing container info")
        }

        if DockerService.needsRecreation(old: oldInfo, new: newInfo) {
            try await docker.recreateContainer(oldTask: oldTask, newTask: newTask)
        } else if oldInfo.restartPolicy != newInfo.restartPolicy {
            try await docker.updateRestartPolicy(task: oldTask, policy: newInfo.restartPolicyEnum)
        }
        // If nothing changed, no-op
    }

    /// Remove a Docker container with cascade options.
    func deleteDockerContainer(task: ScheduledTask, removeVolumes: Bool, removeImage: Bool, composeDown: Bool) async {
        beginLoading()
        defer { endLoading() }

        do {
            let docker = DockerService.shared

            if composeDown, let project = task.containerInfo?.composeProject, !project.isEmpty {
                try await docker.composeDown(projectName: project, removeVolumes: removeVolumes)
            } else {
                try await docker.removeWithCascade(task: task, removeVolumes: removeVolumes, removeImage: removeImage)
            }

            if selectedTask?.id == task.id {
                selectedTask = nil
            }

            await historyService.clearHistory(for: task.id)
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func deleteTask(_ task: ScheduledTask) async {
        beginLoading()
        defer { endLoading() }
        AppLogger.shared.info("Deleting task: \(task.launchdLabel)")

        // Snapshot before delete — read content synchronously for launchd,
        // fall back to async for cron (must complete before uninstall erases cron entry)
        if let snapshotContent = readTaskContent(task) {
            let label = task.launchdLabel
            let name = task.name
            let backend = task.backend.rawValue
            let location = task.location
            Task {
                await versionService.saveSnapshotWithContent(
                    snapshotContent, label: label, name: name,
                    reason: .beforeDelete, backend: backend, location: location
                )
            }
        } else if task.backend == .cron {
            await versionService.saveSnapshot(for: task, reason: .beforeDelete)
        }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.uninstall(task: task)

            if selectedTask?.id == task.id {
                selectedTask = nil
            }

            // Execution history preserved until permanent delete from trash

            // Re-discover to reflect deletion
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func toggleTaskEnabled(_ task: ScheduledTask) async {
        guard !activeActionIDs.contains(task.id) else { return }
        activeActionIDs.insert(task.id)
        beginLoading()
        defer {
            activeActionIDs.remove(task.id)
            endLoading()
        }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            if task.isEnabled {
                try await service.disable(task: task)
            } else {
                try await service.enable(task: task)
            }

            // Re-discover to refresh state from live sources
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func runTaskNow(_ task: ScheduledTask) async {
        guard !activeActionIDs.contains(task.id) else { return }
        activeActionIDs.insert(task.id)
        beginLoading()
        defer {
            activeActionIDs.remove(task.id)
            endLoading()
        }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            let result = try await service.runNow(task: task)

            await historyService.recordExecution(result)

            // Re-discover to refresh state
            await discoverAllTasks()

            if !result.success {
                showError(message: "Task failed with exit code \(result.exitCode)")
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadDaemon(_ task: ScheduledTask) async {
        guard !activeActionIDs.contains(task.id) else { return }
        activeActionIDs.insert(task.id)
        beginLoading()
        defer {
            activeActionIDs.remove(task.id)
            endLoading()
        }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.enable(task: task)
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func unloadDaemon(_ task: ScheduledTask) async {
        guard !activeActionIDs.contains(task.id) else { return }
        activeActionIDs.insert(task.id)
        beginLoading()
        defer {
            activeActionIDs.remove(task.id)
            endLoading()
        }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.disable(task: task)
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadAllDaemons() async {
        beginLoading()
        defer { endLoading() }

        let launchdTasks = tasks.filter { $0.backend == .launchd && !$0.isEnabled && !$0.isReadOnly }
        for task in launchdTasks {
            do {
                try await LaunchdService.shared.enable(task: task)
            } catch {
                // Continue loading others even if one fails
            }
        }
        await discoverAllTasks()
    }

    func unloadAllDaemons() async {
        beginLoading()
        defer { endLoading() }

        let launchdTasks = tasks.filter { $0.backend == .launchd && $0.isEnabled && !$0.isReadOnly }
        for task in launchdTasks {
            do {
                try await LaunchdService.shared.disable(task: task)
            } catch {
                // Continue unloading others even if one fails
            }
        }
        await discoverAllTasks()
    }

    func refreshAll() async {
        await discoverAllTasks()
    }

    func refreshTaskStatus(_ task: ScheduledTask) async {
        // Just re-discover everything for consistency
        await discoverAllTasks()
    }

    /// Read the tail of a log file, returning nil if the file doesn't exist or is empty.
    /// Caps at 10K chars to match history truncation limits.
    private static func readLogFile(_ path: String?, maxBytes: Int = 10_000) -> String? {
        guard let path = path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > 0 else {
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let readSize = min(UInt64(maxBytes), fileSize)
        if fileSize > readSize {
            handle.seek(toFileOffset: fileSize - readSize)
        }
        let data = handle.readData(ofLength: Int(readSize))
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else { return nil }
        return content
    }

    // MARK: - Version History

    func revertTask(_ task: ScheduledTask, to snapshot: TaskSnapshot) async {
        beginLoading()
        defer { endLoading() }
        AppLogger.shared.info("Reverting task \(task.launchdLabel) to snapshot from \(snapshot.timestamp)")

        guard let content = await versionService.readSnapshotContent(snapshot) else {
            showError(message: "Could not read snapshot content")
            return
        }

        // Save current version before reverting (fire-and-forget for launchd, blocking for cron)
        if let currentContent = readTaskContent(task) {
            let label = task.launchdLabel
            let name = task.name
            let backend = task.backend.rawValue
            let location = task.location
            Task {
                await versionService.saveSnapshotWithContent(
                    currentContent, label: label, name: name,
                    reason: .beforeEdit, backend: backend, location: location
                )
            }
        } else if task.backend == .cron {
            await versionService.saveSnapshot(for: task, reason: .beforeEdit)
        }

        do {
            if snapshot.backend == SchedulerBackend.launchd.rawValue {
                try await revertLaunchdTask(task, content: content)
            } else if snapshot.backend == SchedulerBackend.cron.rawValue {
                try await revertCronTask(task, content: content)
            }

            await discoverAllTasks()
            selectedTask = tasks.first { $0.launchdLabel == snapshot.taskLabel }
        } catch {
            showError(message: "Revert failed: \(error.localizedDescription)")
        }
    }

    func restoreDeletedTask(from snapshot: TaskSnapshot) async {
        beginLoading()
        defer { endLoading() }
        AppLogger.shared.info("Restoring deleted task \(snapshot.taskLabel) from trash")

        guard let content = await versionService.readSnapshotContent(snapshot) else {
            showError(message: "Could not read snapshot content")
            return
        }

        do {
            if snapshot.backend == SchedulerBackend.launchd.rawValue {
                try await restoreLaunchdTask(content: content, location: snapshot.location ?? .userAgent)
            } else if snapshot.backend == SchedulerBackend.cron.rawValue {
                try await restoreCronTask(content: content, label: snapshot.taskLabel)
            }

            await discoverAllTasks()
            selectedTask = tasks.first { $0.launchdLabel == snapshot.taskLabel }
        } catch {
            showError(message: "Restore failed: \(error.localizedDescription)")
        }
    }

    func permanentlyDeleteTask(label: String) async {
        await versionService.purgeSnapshots(for: label)
        let taskId = ScheduledTask.uuidFromLabel(label)
        await historyService.clearHistory(for: taskId)
    }

    private func revertLaunchdTask(_ task: ScheduledTask, content: String) async throws {
        // Defense-in-depth: only allow revert for user-writable tasks
        guard !task.isReadOnly, task.location == .userAgent else {
            throw SchedulerError.invalidTask("Cannot revert read-only or system tasks")
        }

        let data = Data(content.utf8)

        // Parse snapshot into a ScheduledTask (validates well-formed plist)
        guard var parsedTask = LaunchdService.shared.parsePlistData(data) else {
            throw SchedulerError.invalidTask("Snapshot contains invalid plist data")
        }

        // Strip dangerous env vars (DYLD_INSERT_LIBRARIES, LD_PRELOAD, BASH_ENV, etc.)
        parsedTask.action.environmentVariables = parsedTask.action.environmentVariables.filter { key, _ in
            !PlistGenerator.isDangerousEnvVar(key)
        }

        // Validate the parsed task (label chars, control chars, calendar bounds, etc.)
        let validationErrors = parsedTask.validate()
        if !validationErrors.isEmpty {
            throw SchedulerError.invalidTask("Snapshot failed validation: \(validationErrors.joined(separator: "; "))")
        }

        // Re-generate a clean plist via PlistGenerator (applies XML escaping, control char stripping)
        let cleanPlist = PlistGenerator().generate(for: parsedTask)

        // Unload current task
        let launchdService = LaunchdService.shared
        try? await launchdService.disable(task: task)

        // Write clean plist to LaunchAgents
        let plistURL = URL(fileURLWithPath: task.location.directory).appendingPathComponent(task.plistFileName)

        // Validate the write destination resolves within the LaunchAgents directory
        let resolvedPath = plistURL.resolvingSymlinksInPath().path
        let resolvedDir = URL(fileURLWithPath: task.location.directory).resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(resolvedDir + "/") else {
            throw SchedulerError.invalidTask("Plist path resolves outside LaunchAgents directory")
        }

        try cleanPlist.write(toFile: plistURL.path, atomically: true, encoding: .utf8)

        // Load the reverted task
        try await launchdService.enable(task: task)
    }

    private func revertCronTask(_ task: ScheduledTask, content: String) async throws {
        let cronService = CronService.shared
        try await cronService.uninstall(task: task)

        // The snapshot content is "# CronTask:label\ncron-line" — reinstall via raw crontab manipulation
        try await reinstallCronFromSnapshot(content: content)
    }

    /// Restore into the domain the task was deleted from (System Daemon → /Library/LaunchDaemons, etc.),
    /// so it runs as the same user it did before. Older snapshots without a location restore as user agents.
    private func restoreLaunchdTask(content: String, location: TaskLocation) async throws {
        let data = Data(content.utf8)
        guard var parsedTask = LaunchdService.shared.parsePlistData(data) else {
            throw SchedulerError.invalidTask("Snapshot contains invalid plist data")
        }

        // Strip dangerous env vars (DYLD_INSERT_LIBRARIES, LD_PRELOAD, BASH_ENV, etc.)
        parsedTask.action.environmentVariables = parsedTask.action.environmentVariables.filter { key, _ in
            !PlistGenerator.isDangerousEnvVar(key)
        }

        // Validate the parsed task (label chars, control chars, calendar bounds, etc.)
        let validationErrors = parsedTask.validate()
        if !validationErrors.isEmpty {
            throw SchedulerError.invalidTask("Snapshot failed validation: \(validationErrors.joined(separator: "; "))")
        }

        parsedTask.location = location
        parsedTask.isReadOnly = false
        parsedTask.plistFilePath = nil

        let baseDir = location.directory
        let plistURL = URL(fileURLWithPath: baseDir)
            .appendingPathComponent(parsedTask.plistFileName)

        // Validate the write destination resolves within the target launch directory
        let resolvedPath = plistURL.resolvingSymlinksInPath().path
        let resolvedDir = URL(fileURLWithPath: baseDir).resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(resolvedDir + "/") else {
            throw SchedulerError.invalidTask("Plist path resolves outside \(baseDir)")
        }

        // install() re-generates a clean plist via PlistGenerator (XML escaping, control char
        // stripping) and writes it with elevation for system locations; enable() loads it in
        // the right domain
        try await LaunchdService.shared.install(task: parsedTask)
        try await LaunchdService.shared.enable(task: parsedTask)
    }

    private func restoreCronTask(content: String, label: String) async throws {
        try await reinstallCronFromSnapshot(content: content)
    }

    /// Append raw cron content (tag + cron line) to crontab.
    /// Characters allowed in cron tag labels (same as ScheduledTask.labelAllowedCharacters).
    private static let cronLabelAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    private func reinstallCronFromSnapshot(content: String) async throws {
        // Reject null bytes in cron content
        guard !content.contains("\0") else {
            throw SchedulerError.cronUpdateFailed("Cron content contains null bytes")
        }

        // Validate cron snapshot format: must be exactly "# CronTask:<label>\n<cron-line>"
        let snapshotLines = content.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        guard snapshotLines.count == 2,
              snapshotLines[0].hasPrefix("# CronTask:"),
              !snapshotLines[1].hasPrefix("#") else {
            throw SchedulerError.cronUpdateFailed("Invalid cron snapshot format")
        }

        // Validate the tag label characters match allowlist [a-zA-Z0-9._-]
        let tagLabel = String(snapshotLines[0].dropFirst("# CronTask:".count))
        guard !tagLabel.isEmpty,
              tagLabel.rangeOfCharacter(from: Self.cronLabelAllowedCharacters.inverted) == nil else {
            throw SchedulerError.cronUpdateFailed("Cron tag label contains invalid characters")
        }

        // Validate the cron line has at least 6 fields (5 schedule + command)
        let cronFields = snapshotLines[1].split(separator: " ", maxSplits: 5)
        guard cronFields.count >= 6 else {
            throw SchedulerError.cronUpdateFailed("Invalid cron entry: insufficient fields")
        }

        // Validate the 5 schedule fields are either "*" or numeric (no shell injection)
        for i in 0..<5 {
            let field = String(cronFields[i])
            if field != "*" {
                // Allow numeric values, ranges (1-5), steps (*/2), lists (1,3,5), and combinations
                let scheduleAllowed = CharacterSet(charactersIn: "0123456789,/-*")
                guard field.rangeOfCharacter(from: scheduleAllowed.inverted) == nil else {
                    throw SchedulerError.cronUpdateFailed("Cron schedule field \(i + 1) contains invalid characters: \(field)")
                }
            }
        }

        // Strip control chars from the command portion (field 6+)
        let commandPortion = String(cronFields[5])
        let cleanCommand = String(commandPortion.unicodeScalars.filter { scalar in
            // Keep tab (0x09), newline (0x0A), CR (0x0D); strip all other control chars
            if scalar.isASCII && scalar.value < 0x20 {
                return scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
            }
            return true
        })

        // Reassemble the clean cron line
        let scheduleFields = cronFields[0..<5].joined(separator: " ")
        let cleanCronLine = "\(scheduleFields) \(cleanCommand)"
        let cleanSnapshotLines = [snapshotLines[0], cleanCronLine]

        let shellExecutor = ShellExecutor.shared
        let currentResult = try await shellExecutor.execute(command: "/usr/bin/crontab", arguments: ["-l"])
        var lines: [String]
        if currentResult.exitCode == 0 {
            lines = currentResult.standardOutput.components(separatedBy: "\n")
        } else {
            lines = []
        }

        // Append validated and cleaned snapshot content
        lines.append(contentsOf: cleanSnapshotLines)

        let crontabContent = lines.joined(separator: "\n")
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".crontab")
        let data = Data(crontabContent.utf8)
        guard FileManager.default.createFile(atPath: tempFile.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw SchedulerError.cronUpdateFailed("Failed to create temp crontab file")
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = try await shellExecutor.execute(command: "/usr/bin/crontab", arguments: [tempFile.path])
        if result.exitCode != 0 {
            throw SchedulerError.cronUpdateFailed(result.standardError)
        }
    }

    /// Read the current config content for a task synchronously on the main actor.
    /// Returns plist content for launchd tasks, nil for others (cron snapshots
    /// fall back to the async path inside TaskVersionService).
    /// Bounded to 1 MB to prevent OOM.
    private static let maxPlistReadSize = 1_048_576

    private func readTaskContent(_ task: ScheduledTask) -> String? {
        switch task.backend {
        case .launchd:
            guard let path = task.plistFilePath,
                  FileManager.default.fileExists(atPath: path),
                  let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: Self.maxPlistReadSize)
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private func showError(message: String) {
        AppLogger.shared.error(message)
        errorMessage = message
        showError = true
    }

}
