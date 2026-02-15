//
//  TaskAction.swift
//  MacScheduler
//
//  Defines the action types that can be performed by a scheduled task.
//

import Foundation

enum TaskActionType: String, Codable, CaseIterable {
    case executable = "Executable"
    case shellScript = "Shell Script"
    case appleScript = "AppleScript"

    var description: String {
        switch self {
        case .executable: return "Run an application or executable"
        case .shellScript: return "Run a shell script or command"
        case .appleScript: return "Run an AppleScript"
        }
    }

    var systemImage: String {
        switch self {
        case .executable: return "app.badge.checkmark"
        case .shellScript: return "terminal"
        case .appleScript: return "applescript"
        }
    }
}

struct TaskAction: Codable, Equatable, Identifiable {
    let id: UUID
    var type: TaskActionType
    var path: String
    var arguments: [String]
    var workingDirectory: String?
    var environmentVariables: [String: String]
    var scriptContent: String?

    init(id: UUID = UUID(),
         type: TaskActionType = .executable,
         path: String = "",
         arguments: [String] = [],
         workingDirectory: String? = nil,
         environmentVariables: [String: String] = [:],
         scriptContent: String? = nil) {
        self.id = id
        self.type = type
        self.path = path
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self.scriptContent = scriptContent
    }

    var displayName: String {
        if !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        return type.rawValue
    }

    var commandPreview: String {
        switch type {
        case .executable:
            if arguments.isEmpty {
                return path
            }
            return "\(path) \(arguments.joined(separator: " "))"
        case .shellScript:
            return scriptContent ?? path
        case .appleScript:
            if let script = scriptContent, !script.isEmpty {
                let preview = script.prefix(50)
                return script.count > 50 ? "\(preview)..." : String(preview)
            }
            return path
        }
    }

    /// Check if a string contains null bytes or non-tab/non-newline control characters.
    private static func containsDangerousChars(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.value == 0 || (scalar.isASCII && scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13)
        }
    }

    func validate() -> [String] {
        var errors: [String] = []

        // Validate path for dangerous characters
        if !path.isEmpty && Self.containsDangerousChars(path) {
            errors.append("Path contains invalid control characters")
        }

        // Validate arguments for dangerous characters
        for (i, arg) in arguments.enumerated() {
            if Self.containsDangerousChars(arg) {
                errors.append("Argument \(i + 1) contains invalid control characters")
            }
        }

        switch type {
        case .executable:
            if path.isEmpty {
                errors.append("Executable path is required")
            } else if !path.contains("\0"), !FileManager.default.fileExists(atPath: path) {
                errors.append("Executable not found at path: \(path)")
            }
        case .shellScript:
            if path.isEmpty && (scriptContent?.isEmpty ?? true) {
                errors.append("Script path or content is required")
            }
        case .appleScript:
            if path.isEmpty && (scriptContent?.isEmpty ?? true) {
                errors.append("AppleScript path or content is required")
            }
        }

        // Validate working directory
        if let workDir = workingDirectory, !workDir.isEmpty {
            if Self.containsDangerousChars(workDir) {
                errors.append("Working directory contains invalid control characters")
            } else {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: workDir, isDirectory: &isDir) || !isDir.boolValue {
                    errors.append("Working directory does not exist: \(workDir)")
                }
            }
        }

        // Validate script content for null bytes
        if let script = scriptContent, script.contains("\0") {
            errors.append("Script content contains null bytes")
        }

        return errors
    }
}
