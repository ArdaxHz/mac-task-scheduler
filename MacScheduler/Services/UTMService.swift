//
//  UTMService.swift
//  MacScheduler
//
//  Service for discovering and managing UTM virtual machines.
//

import Foundation

class UTMService: SchedulerService {
    static let shared = UTMService()
    let backend: SchedulerBackend = .utm

    private let shellExecutor = ShellExecutor.shared

    private let utmctlPaths = [
        "/Applications/UTM.app/Contents/MacOS/utmctl",
        "/usr/local/bin/utmctl"
    ]

    private init() {}

    private var utmctlPath: String? {
        utmctlPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Validate that the VM ID is a valid UUID (defense-in-depth).
    private func validateVMId(_ vmId: String) -> Bool {
        UUID(uuidString: vmId) != nil && !vmId.contains("\0")
    }

    // MARK: - SchedulerService Protocol

    func install(task: ScheduledTask) async throws {
        throw SchedulerError.vmOperationNotSupported("Cannot create VMs through this app")
    }

    func uninstall(task: ScheduledTask) async throws {
        throw SchedulerError.vmOperationNotSupported("Cannot delete VMs through this app")
    }

    func enable(task: ScheduledTask) async throws {
        guard let utmctl = utmctlPath else {
            throw SchedulerError.vmNotAvailable("utmctl not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid UTM VM")
        }
        let result = try await shellExecutor.execute(
            command: utmctl,
            arguments: ["start", info.vmId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.vmCommandFailed("Failed to start VM: \(result.standardError)")
        }
    }

    func disable(task: ScheduledTask) async throws {
        guard let utmctl = utmctlPath else {
            throw SchedulerError.vmNotAvailable("utmctl not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid UTM VM")
        }
        let result = try await shellExecutor.execute(
            command: utmctl,
            arguments: ["stop", info.vmId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.vmCommandFailed("Failed to stop VM: \(result.standardError)")
        }
    }

    func runNow(task: ScheduledTask) async throws -> TaskExecutionResult {
        throw SchedulerError.vmOperationNotSupported("Use Start/Stop for VMs")
    }

    func isInstalled(task: ScheduledTask) async -> Bool {
        guard let utmctl = utmctlPath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: utmctl,
                arguments: ["status", info.vmId],
                timeout: 10.0
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        guard let utmctl = utmctlPath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: utmctl,
                arguments: ["status", info.vmId],
                timeout: 10.0
            )
            return result.exitCode == 0 && result.standardOutput.lowercased().contains("started")
        } catch {
            return false
        }
    }

    // MARK: - Discovery

    func discoverTasks() async throws -> [ScheduledTask] {
        guard let utmctl = utmctlPath else { return [] }

        // utmctl list outputs tab-separated: UUID\tStatus\tName
        let result = try await shellExecutor.execute(
            command: utmctl,
            arguments: ["list"],
            timeout: 15.0
        )
        guard result.exitCode == 0 else { return [] }

        let lines = result.standardOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        var tasks: [ScheduledTask] = []

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            // Skip header line or malformed lines
            guard parts.count >= 3 else { continue }

            let uuid = parts[0].trimmingCharacters(in: .whitespaces)
            let status = parts[1].trimmingCharacters(in: .whitespaces)
            let name = parts[2].trimmingCharacters(in: .whitespaces)

            // Validate UUID format
            guard UUID(uuidString: uuid) != nil else { continue }

            let taskState = mapVMState(status)
            let sanitizedName = sanitizeVMName(name)
            let label = "utm.\(sanitizedName)"

            let vmInfo = VMInfo(
                vmId: uuid,
                vmName: name,
                vmState: status,
                backend: .utm,
                osType: nil
            )

            let task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(label),
                name: name,
                description: "UTM VM",
                backend: .utm,
                action: TaskAction(type: .executable, path: "utmctl"),
                trigger: .onDemand,
                status: TaskStatus(state: taskState),
                createdAt: Date(),
                modifiedAt: Date(),
                launchdLabel: label,
                isReadOnly: true,
                location: .userAgent,
                vmInfo: vmInfo
            )
            tasks.append(task)
        }
        return tasks
    }

    // MARK: - Helpers

    private func mapVMState(_ status: String) -> TaskState {
        switch status.lowercased() {
        case "started", "running": return .running
        case "stopped", "suspended": return .disabled
        case "paused": return .disabled
        default: return .disabled
        }
    }

    private func sanitizeVMName(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar in
            if scalar.isASCII,
               "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars.contains(scalar) {
                return Character(scalar)
            }
            return Character("-")
        })
    }
}
