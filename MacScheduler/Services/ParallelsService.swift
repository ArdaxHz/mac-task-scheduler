//
//  ParallelsService.swift
//  MacScheduler
//
//  Service for discovering and managing Parallels Desktop virtual machines.
//

import Foundation

class ParallelsService: SchedulerService {
    static let shared = ParallelsService()
    let backend: SchedulerBackend = .parallels

    private let shellExecutor = ShellExecutor.shared

    private let prlctlPaths = [
        "/usr/local/bin/prlctl",
        "/opt/homebrew/bin/prlctl"
    ]

    private init() {}

    private var prlctlPath: String? {
        prlctlPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
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
        guard let prlctl = prlctlPath else {
            throw SchedulerError.vmNotAvailable("prlctl not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid Parallels VM")
        }
        let result = try await shellExecutor.execute(
            command: prlctl,
            arguments: ["start", info.vmId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.vmCommandFailed("Failed to start VM: \(result.standardError)")
        }
    }

    func disable(task: ScheduledTask) async throws {
        guard let prlctl = prlctlPath else {
            throw SchedulerError.vmNotAvailable("prlctl not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid Parallels VM")
        }
        let result = try await shellExecutor.execute(
            command: prlctl,
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
        guard let prlctl = prlctlPath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: prlctl,
                arguments: ["status", info.vmId],
                timeout: 10.0
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        guard let prlctl = prlctlPath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: prlctl,
                arguments: ["status", info.vmId],
                timeout: 10.0
            )
            return result.exitCode == 0 && result.standardOutput.contains("running")
        } catch {
            return false
        }
    }

    // MARK: - Discovery

    func discoverTasks() async throws -> [ScheduledTask] {
        guard let prlctl = prlctlPath else { return [] }

        let result = try await shellExecutor.execute(
            command: prlctl,
            arguments: ["list", "-a", "--json"],
            timeout: 15.0
        )
        guard result.exitCode == 0,
              let data = result.standardOutput.data(using: .utf8) else {
            return []
        }

        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var tasks: [ScheduledTask] = []
        for entry in entries {
            guard let uuid = entry["uuid"] as? String,
                  let name = entry["name"] as? String,
                  let status = entry["status"] as? String else {
                continue
            }

            // Validate UUID format
            guard UUID(uuidString: uuid) != nil else { continue }

            let osType = entry["os"] as? String
            let taskState = mapVMState(status)
            let sanitizedName = sanitizeVMName(name)
            let label = "parallels.\(sanitizedName)"

            let vmInfo = VMInfo(
                vmId: uuid,
                vmName: name,
                vmState: status,
                backend: .parallels,
                osType: osType
            )

            let task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(label),
                name: name,
                description: "Parallels VM",
                backend: .parallels,
                action: TaskAction(type: .executable, path: "prlctl"),
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
        case "running": return .running
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
