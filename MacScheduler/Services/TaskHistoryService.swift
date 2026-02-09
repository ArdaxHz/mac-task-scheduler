//
//  TaskHistoryService.swift
//  MacScheduler
//
//  Service for tracking task execution history.
//

import Foundation

actor TaskHistoryService {
    static let shared = TaskHistoryService()

    private let fileManager = FileManager.default
    private var history: [UUID: [TaskExecutionResult]] = [:]
    private let maxHistoryPerTask = 100

    /// Maximum characters to store per output stream in history.
    private let maxOutputChars = 10_000

    /// Debounce save: schedule a save after a short delay to coalesce rapid writes.
    private var pendingSave: Task<Void, Never>?

    private var historyFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacScheduler")
        return appDir.appendingPathComponent("history.json")
    }

    private init() {
        Task {
            await loadHistory()
        }
    }

    func recordExecution(_ result: TaskExecutionResult) {
        // Truncate large outputs before storing to prevent history.json bloat
        let truncated = TaskExecutionResult(
            taskId: result.taskId,
            startTime: result.startTime,
            endTime: result.endTime,
            exitCode: result.exitCode,
            standardOutput: Self.truncateOutput(result.standardOutput, maxChars: maxOutputChars),
            standardError: Self.truncateOutput(result.standardError, maxChars: maxOutputChars)
        )

        var taskHistory = history[truncated.taskId] ?? []
        taskHistory.insert(truncated, at: 0)

        if taskHistory.count > maxHistoryPerTask {
            taskHistory = Array(taskHistory.prefix(maxHistoryPerTask))
        }

        history[truncated.taskId] = taskHistory

        scheduleSave()
    }

    private static func truncateOutput(_ output: String, maxChars: Int) -> String {
        guard output.count > maxChars else { return output }
        return String(output.prefix(maxChars)) + "\n[... truncated at \(maxChars) chars ...]"
    }

    func getHistory(for taskId: UUID) -> [TaskExecutionResult] {
        history[taskId] ?? []
    }

    func getAllHistory() -> [TaskExecutionResult] {
        history.values.flatMap { $0 }.sorted { $0.startTime > $1.startTime }
    }

    func getRecentHistory(limit: Int = 50) -> [TaskExecutionResult] {
        Array(getAllHistory().prefix(limit))
    }

    func clearHistory(for taskId: UUID) {
        history.removeValue(forKey: taskId)
        scheduleSave()
    }

    func clearAllHistory() {
        history.removeAll()
        scheduleSave()
    }

    /// Debounce disk writes: cancel any pending save and schedule a new one after 500ms.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            await performSave()
        }
    }

    /// Force an immediate save (called on app termination or explicit flush).
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await performSave()
    }

    private func loadHistory() {
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let allResults = try decoder.decode([TaskExecutionResult].self, from: data)

            // Group by taskId in a single pass
            var grouped: [UUID: [TaskExecutionResult]] = [:]
            grouped.reserveCapacity(Set(allResults.map(\.taskId)).count)
            for result in allResults {
                grouped[result.taskId, default: []].append(result)
            }

            // Sort each group once
            for taskId in grouped.keys {
                grouped[taskId]?.sort { $0.startTime > $1.startTime }
            }

            history = grouped
        } catch {
            print("Failed to load history: \(error)")
        }
    }

    private func performSave() async {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacScheduler")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        do {
            let allResults = history.values.flatMap { $0 }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(allResults)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
}
