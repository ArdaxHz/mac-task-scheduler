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

    /// Maximum characters to store per output stream in history.
    private let maxOutputChars = 10_000

    func recordExecution(_ result: TaskExecutionResult) async {
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

        await saveHistory()
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

    func clearHistory(for taskId: UUID) async {
        history.removeValue(forKey: taskId)
        await saveHistory()
    }

    func clearAllHistory() async {
        history.removeAll()
        await saveHistory()
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

            for result in allResults {
                var taskHistory = history[result.taskId] ?? []
                taskHistory.append(result)
                history[result.taskId] = taskHistory
            }

            for taskId in history.keys {
                history[taskId]?.sort { $0.startTime > $1.startTime }
            }
        } catch {
            print("Failed to load history: \(error)")
        }
    }

    private func saveHistory() async {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacScheduler")

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        do {
            let allResults = history.values.flatMap { $0 }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted

            let data = try encoder.encode(allResults)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
}
