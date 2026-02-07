//
//  ShellExecutor.swift
//  MacScheduler
//
//  Utility for safely executing shell commands.
//

import Foundation

struct ShellResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

actor ShellExecutor {
    static let shared = ShellExecutor()

    private init() {}

    func execute(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60.0
    ) async throws -> ShellResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: command) && !fm.isExecutableFile(atPath: command) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        do {
            try process.run()
        } catch {
            throw SchedulerError.commandExecutionFailed("Failed to start process: \(error.localizedDescription)")
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func executeScript(
        _ script: String,
        shell: String = "/bin/bash",
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60.0
    ) async throws -> ShellResult {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(UUID().uuidString + ".sh")

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        return try await execute(
            command: shell,
            arguments: [scriptURL.path],
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
    }
}
