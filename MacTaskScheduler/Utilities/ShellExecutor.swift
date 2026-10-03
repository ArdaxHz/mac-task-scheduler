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

        // Drain pipes while the process runs (avoids pipe-buffer deadlock).
        // Non-blocking handlers so a grandchild holding the pipe open (`cmd &`)
        // can't stall us after the process itself exits.
        let stdoutBuf = BoundedBuffer(maxBytes: Self.maxOutputBytes)
        let stderrBuf = BoundedBuffer(maxBytes: Self.maxOutputBytes)
        outputPipe.fileHandleForReading.readabilityHandler = { stdoutBuf.consume($0) }
        errorPipe.fileHandleForReading.readabilityHandler = { stderrBuf.consume($0) }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
            guard process.processIdentifier > 0 else { return }

            // Timeout starts at launch: SIGTERM, then SIGKILL if ignored.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }

        guard process.processIdentifier > 0 else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw SchedulerError.commandExecutionFailed("Failed to start process: \(command)")
        }

        // Give the handlers up to 1s to deliver trailing output and EOF.
        for _ in 0..<20 where !(stdoutBuf.isFinished && stderrBuf.isFinished) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let output = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
        let error = String(data: stderrBuf.data, encoding: .utf8) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Thread-safe, size-bounded accumulator fed by a pipe's readabilityHandler.
    private final class BoundedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var accumulated = Data()
        private var hitLimit = false
        private var finished = false

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func consume(_ handle: FileHandle) {
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { // EOF
                finished = true
                handle.readabilityHandler = nil
                return
            }
            // Keep draining past the limit so the process isn't blocked on a full pipe
            let remaining = maxBytes - accumulated.count
            if remaining > 0 { accumulated.append(chunk.prefix(remaining)) }
            if accumulated.count >= maxBytes { hitLimit = true }
        }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            guard hitLimit else { return accumulated }
            return accumulated + Data("\n[... output truncated at \(maxBytes / 1024)KB ...]".utf8)
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
