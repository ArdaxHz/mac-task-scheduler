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
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var searchText = ""
    @Published var filterBackend: SchedulerBackend?
    @Published var filterStates: Set<TaskState> = []
    @Published var filterTriggerType: TriggerType?
    @Published var filterLastRun: LastRunFilter = .all
    @Published var filterOwnership: OwnershipFilter = .all
    @Published var filterLocation: LocationFilter = .all

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
        Task {
            await discoverAllTasks()
        }
    }

    /// Discover all tasks from live LaunchAgents and cron files.
    func discoverAllTasks() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let launchdService = LaunchdService.shared
            let cronService = CronService.shared

            // Fetch launchd + cron tasks in parallel
            async let launchdResult = launchdService.discoverTasks()
            async let cronResult = cronService.discoverTasks()
            let (launchdTasks, cronTasks) = try await (launchdResult, cronResult)

            // Dedup by task ID (deterministic UUID from label) — prefer user-writable over read-only
            var tasksById: [UUID: ScheduledTask] = [:]
            tasksById.reserveCapacity(launchdTasks.count + cronTasks.count)
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
            }

            allTasks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            tasks = allTasks

            // Update selected task if it still exists
            if let selected = selectedTask,
               let updated = tasks.first(where: { $0.launchdLabel == selected.launchdLabel }) {
                selectedTask = updated
            } else if selectedTask != nil {
                selectedTask = nil
            }
        } catch {
            showError(message: "Failed to discover tasks: \(error.localizedDescription)")
        }
    }

    func addTask(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.install(task: task)

            // Always load into launchd to register the daemon
            try await service.enable(task: task)

            // If user wants it disabled, unload after registering
            if !task.isEnabled {
                try await service.disable(task: task)
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
        isLoading = true
        defer { isLoading = false }

        guard let oldTask = tasks.first(where: { $0.id == task.id }) else {
            showError(message: "Task not found")
            return
        }

        do {
            if task.backend == .launchd {
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

    func deleteTask(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.uninstall(task: task)

            if selectedTask?.id == task.id {
                selectedTask = nil
            }

            await historyService.clearHistory(for: task.id)

            // Re-discover to reflect deletion
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func toggleTaskEnabled(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

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
        isLoading = true
        defer { isLoading = false }

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
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.enable(task: task)
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func unloadDaemon(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.disable(task: task)
            await discoverAllTasks()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadAllDaemons() async {
        isLoading = true
        defer { isLoading = false }

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
        isLoading = true
        defer { isLoading = false }

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

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
