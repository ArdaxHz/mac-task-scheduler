//
//  TaskStatus.swift
//  MacScheduler
//
//  Represents the execution status of a scheduled task.
//

import Foundation

enum TaskState: String, Codable, CaseIterable {
    case enabled = "Enabled"
    case disabled = "Disabled"
    case running = "Running"
    case error = "Error"

    var systemImage: String {
        switch self {
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .running: return "play.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }
}

struct TaskExecutionResult: Codable, Identifiable, Equatable {
    let id: UUID
    let taskId: UUID
    let startTime: Date
    let endTime: Date
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var success: Bool {
        exitCode == 0
    }

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    init(taskId: UUID, startTime: Date, endTime: Date, exitCode: Int32,
         standardOutput: String = "", standardError: String = "") {
        self.id = UUID()
        self.taskId = taskId
        self.startTime = startTime
        self.endTime = endTime
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

struct TaskStatus: Codable, Equatable {
    var state: TaskState
    var lastRun: Date?
    var lastResult: TaskExecutionResult?
    var nextScheduledRun: Date?
    var runCount: Int
    var failureCount: Int
    /// For running tasks: when the current process started.
    var processStartTime: Date?
    /// For error tasks: the last exit code from launchctl.
    var lastExitStatus: Int32?

    init(state: TaskState = .disabled,
         lastRun: Date? = nil,
         lastResult: TaskExecutionResult? = nil,
         nextScheduledRun: Date? = nil,
         runCount: Int = 0,
         failureCount: Int = 0,
         processStartTime: Date? = nil,
         lastExitStatus: Int32? = nil) {
        self.state = state
        self.lastRun = lastRun
        self.lastResult = lastResult
        self.nextScheduledRun = nextScheduledRun
        self.runCount = runCount
        self.failureCount = failureCount
        self.processStartTime = processStartTime
        self.lastExitStatus = lastExitStatus
    }
}
