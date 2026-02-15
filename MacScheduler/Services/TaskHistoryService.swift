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

    /// Maximum total entries across all tasks to bound memory usage.
    private let maxTotalEntries = 10_000

    /// Debounce save: schedule a save after a short delay to coalesce rapid writes.
    private var pendingSave: Task<Void, Never>?

    private var historyFileURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory.appendingPathComponent("MacScheduler/history.json")
        }
        let appDir = appSupport.appendingPathComponent("MacScheduler")
        return appDir.appendingPathComponent("history.json")
    }

    private init() {
        Task {
            await loadHistory()
            await purgeOldEntries()
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

    /// Remove entries older than the configured retention period and enforce total entry cap.
    private func purgeOldEntries() {
        let retentionDays = UserDefaults.standard.integer(forKey: "logRetentionDays")
        guard retentionDays > 0 else { return } // 0 = keep forever

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        var didPurge = false

        for taskId in history.keys {
            let before = history[taskId]?.count ?? 0
            history[taskId] = history[taskId]?.filter { $0.startTime > cutoff }
            if history[taskId]?.isEmpty == true {
                history.removeValue(forKey: taskId)
            }
            if (history[taskId]?.count ?? 0) != before {
                didPurge = true
            }
        }

        // Enforce total entry cap to bound memory
        let totalCount = history.values.reduce(0) { $0 + $1.count }
        if totalCount > maxTotalEntries {
            var all = history.values.flatMap { $0 }.sorted { $0.startTime > $1.startTime }
            let keep = Set(all.prefix(maxTotalEntries).map { $0.id })
            for taskId in history.keys {
                history[taskId] = history[taskId]?.filter { keep.contains($0.id) }
                if history[taskId]?.isEmpty == true {
                    history.removeValue(forKey: taskId)
                }
            }
            didPurge = true
        }

        if didPurge {
            scheduleSave()
        }
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
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
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
