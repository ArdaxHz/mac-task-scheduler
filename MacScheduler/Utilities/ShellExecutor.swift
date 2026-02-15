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

    /// Maximum bytes to capture per stream (stdout/stderr) to prevent memory exhaustion.
    private static let maxOutputBytes = 1_048_576 // 1 MB

    private init() {}

    func execute(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60.0
    ) async throws -> ShellResult {
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

        // Always filter dangerous env vars from the process environment,
        // even when no custom env is specified (prevents inheriting DYLD_INSERT_LIBRARIES etc.)
        var processEnv = ProcessInfo.processInfo.environment
        for key in processEnv.keys where PlistGenerator.isDangerousEnvVar(key) {
            processEnv.removeValue(forKey: key)
        }
        if let env = environment {
            for (key, value) in env {
                if !PlistGenerator.isDangerousEnvVar(key) {
                    processEnv[key] = value
                }
            }
        }
        process.environment = processEnv

        do {
            try process.run()
        } catch {
            throw SchedulerError.commandExecutionFailed("Failed to start process: \(error.localizedDescription)")
        }

        // Read pipes concurrently BEFORE waitUntilExit to avoid deadlock.
        // If the process writes more than the pipe buffer (~64KB) and we only
        // read after exit, both sides block forever.
        let maxBytes = Self.maxOutputBytes
        let outputData: Data
        let errorData: Data
        do {
            async let stdoutData = Self.readPipeBounded(outputPipe, maxBytes: maxBytes)
            async let stderrData = Self.readPipeBounded(errorPipe, maxBytes: maxBytes)
            outputData = try await stdoutData
            errorData = try await stderrData
        } catch {
            process.terminate()
            throw SchedulerError.commandExecutionFailed("Failed reading process output: \(error.localizedDescription)")
        }

        // Now safe to wait — pipes have been drained
        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Read from a pipe with a bounded size limit to prevent memory exhaustion.
    private static func readPipeBounded(_ pipe: Pipe, maxBytes: Int) async throws -> Data {
        let handle = pipe.fileHandleForReading
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var accumulated = Data()
                var hitLimit = false

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF

                    if !hitLimit {
                        let remaining = maxBytes - accumulated.count
                        if remaining > 0 {
                            accumulated.append(chunk.prefix(remaining))
                        }
                        if accumulated.count >= maxBytes {
                            hitLimit = true
                        }
                    }
                    // Continue reading even after limit to drain the pipe and unblock the process
                }

                if hitLimit {
                    let notice = "\n[... output truncated at \(maxBytes / 1024)KB ...]".data(using: .utf8) ?? Data()
                    accumulated.append(notice)
                }

                continuation.resume(returning: accumulated)
            }
        }
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

        // Use 0o700 (owner-only) instead of 0o755 to prevent other users from reading/modifying
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
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
