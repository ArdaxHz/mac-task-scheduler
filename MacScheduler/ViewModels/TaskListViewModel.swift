//
//  TaskListViewModel.swift
//  MacScheduler
//
//  ViewModel for managing the list of scheduled tasks.
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

    enum LastRunFilter: String, CaseIterable {
        case all = "All"
        case hasRun = "Has Run"
        case neverRun = "Never Run"
    }

    private let fileManager = FileManager.default
    private let historyService = TaskHistoryService.shared

    private var tasksFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacScheduler")
        return appDir.appendingPathComponent("tasks.json")
    }

    var filteredTasks: [ScheduledTask] {
        var result = tasks

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
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

        return result
    }

    var enabledTaskCount: Int {
        tasks.filter { $0.status.state == .enabled }.count
    }

    var disabledTaskCount: Int {
        tasks.filter { $0.status.state == .disabled }.count
    }

    init() {
        loadTasks()
    }

    func loadTasks() {
        guard fileManager.fileExists(atPath: tasksFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: tasksFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tasks = try decoder.decode([ScheduledTask].self, from: data)
        } catch {
            showError(message: "Failed to load tasks: \(error.localizedDescription)")
        }
    }

    func saveTasks() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacScheduler")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted

            let data = try encoder.encode(tasks)
            try data.write(to: tasksFileURL, options: .atomic)
        } catch {
            showError(message: "Failed to save tasks: \(error.localizedDescription)")
        }
    }

    func addTask(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            try await service.install(task: task)

            let newTask = task
            if newTask.status.state == .enabled {
                try await service.enable(task: newTask)
            }

            tasks.append(newTask)
            saveTasks()
            selectedTask = newTask
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func updateTask(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            showError(message: "Task not found")
            return
        }

        do {
            let oldTask = tasks[index]
            let service = SchedulerServiceFactory.service(for: task.backend)

            if oldTask.backend != task.backend {
                let oldService = SchedulerServiceFactory.service(for: oldTask.backend)
                try await oldService.uninstall(task: oldTask)
                try await service.install(task: task)
            } else {
                try await service.update(task: task)
            }

            tasks[index] = task
            saveTasks()

            if selectedTask?.id == task.id {
                selectedTask = task
            }
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

            tasks.removeAll { $0.id == task.id }
            saveTasks()

            if selectedTask?.id == task.id {
                selectedTask = nil
            }

            await historyService.clearHistory(for: task.id)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func toggleTaskEnabled(_ task: ScheduledTask) async {
        var updatedTask = task
        if task.isEnabled {
            updatedTask.disable()
        } else {
            updatedTask.enable()
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)
            if updatedTask.isEnabled {
                try await service.enable(task: task)
            } else {
                try await service.disable(task: task)
            }

            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updatedTask
                saveTasks()

                if selectedTask?.id == task.id {
                    selectedTask = updatedTask
                }
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func runTaskNow(_ task: ScheduledTask) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let service = SchedulerServiceFactory.service(for: task.backend)

            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].markRunning()
            }

            let result = try await service.runNow(task: task)

            await historyService.recordExecution(result)

            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].recordExecution(result)
                saveTasks()

                if selectedTask?.id == task.id {
                    selectedTask = tasks[index]
                }
            }

            if !result.success {
                showError(message: "Task failed with exit code \(result.exitCode)")
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func discoverExistingTasks() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let launchdService = LaunchdService.shared
            let cronService = CronService.shared

            let launchdTasks = try await launchdService.discoverTasks()
            let cronTasks = try await cronService.discoverTasks()

            let existingIds = Set(tasks.map { $0.id })

            for task in launchdTasks where !existingIds.contains(task.id) {
                tasks.append(task)
            }

            for task in cronTasks where !existingIds.contains(task.id) {
                tasks.append(task)
            }

            saveTasks()
        } catch {
            showError(message: "Failed to discover tasks: \(error.localizedDescription)")
        }
    }

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }

        loadTasks()

        for task in tasks {
            await refreshTaskStatus(task)
        }
    }

    func refreshTaskStatus(_ task: ScheduledTask) async {
        let service = SchedulerServiceFactory.service(for: task.backend)
        let isRunning = await service.isRunning(task: task)

        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            if isRunning && tasks[index].status.state != .running {
                tasks[index].status.state = .enabled
            } else if !isRunning && tasks[index].status.state == .running {
                tasks[index].status.state = .enabled
            }
            saveTasks()
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
