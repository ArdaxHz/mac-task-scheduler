//
//  VirtualBoxService.swift
//  MacScheduler
//
//  Service for discovering and managing VirtualBox virtual machines.
//

import Foundation

class VirtualBoxService: SchedulerService {
    static let shared = VirtualBoxService()
    let backend: SchedulerBackend = .virtualBox

    private let shellExecutor = ShellExecutor.shared

    private let vboxManagePaths = [
        "/usr/local/bin/VBoxManage",
        "/Applications/VirtualBox.app/Contents/MacOS/VBoxManage"
    ]

    private init() {}

    private var vboxManagePath: String? {
        vboxManagePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
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
        guard let vboxManage = vboxManagePath else {
            throw SchedulerError.vmNotAvailable("VBoxManage not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid VirtualBox VM")
        }
        let result = try await shellExecutor.execute(
            command: vboxManage,
            arguments: ["startvm", info.vmId, "--type", "headless"],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.vmCommandFailed("Failed to start VM: \(result.standardError)")
        }
    }

    func disable(task: ScheduledTask) async throws {
        guard let vboxManage = vboxManagePath else {
            throw SchedulerError.vmNotAvailable("VBoxManage not found")
        }
        guard let info = task.vmInfo, validateVMId(info.vmId) else {
            throw SchedulerError.invalidTask("Not a valid VirtualBox VM")
        }
        let result = try await shellExecutor.execute(
            command: vboxManage,
            arguments: ["controlvm", info.vmId, "acpipowerbutton"],
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
        guard let vboxManage = vboxManagePath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: vboxManage,
                arguments: ["showvminfo", info.vmId, "--machinereadable"],
                timeout: 10.0
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        guard let vboxManage = vboxManagePath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: vboxManage,
                arguments: ["showvminfo", info.vmId, "--machinereadable"],
                timeout: 10.0
            )
            return result.exitCode == 0 && result.standardOutput.contains("VMState=\"running\"")
        } catch {
            return false
        }
    }

    // MARK: - Discovery

    func discoverTasks() async throws -> [ScheduledTask] {
        guard let vboxManage = vboxManagePath else { return [] }

        // List all VMs: output is "Name" {UUID} per line
        let listResult = try await shellExecutor.execute(
            command: vboxManage,
            arguments: ["list", "vms"],
            timeout: 15.0
        )
        guard listResult.exitCode == 0 else { return [] }

        // List running VMs for state detection
        let runningResult = try await shellExecutor.execute(
            command: vboxManage,
            arguments: ["list", "runningvms"],
            timeout: 15.0
        )
        let runningIds = Set(parseVMList(runningResult.standardOutput).map(\.1))

        let allVMs = parseVMList(listResult.standardOutput)
        if allVMs.isEmpty { return [] }

        var tasks: [ScheduledTask] = []
        for (name, uuid) in allVMs {
            // Validate UUID
            guard UUID(uuidString: uuid) != nil else { continue }

            let isRunning = runningIds.contains(uuid)

            // Get details (CPU, memory, OS type) — non-blocking, individual failure OK
            var cpuCount: Int?
            var memoryMB: Int?
            var osType: String?
            if let details = try? await getVMDetails(uuid) {
                cpuCount = details.cpuCount
                memoryMB = details.memoryMB
                osType = details.osType
            }

            let sanitizedName = sanitizeVMName(name)
            let label = "virtualbox.\(sanitizedName)"

            let vmInfo = VMInfo(
                vmId: uuid,
                vmName: name,
                vmState: isRunning ? "running" : "poweroff",
                backend: .virtualBox,
                osType: osType,
                cpuCount: cpuCount,
                memoryMB: memoryMB
            )

            let task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(label),
                name: name,
                description: "VirtualBox VM",
                backend: .virtualBox,
                action: TaskAction(type: .executable, path: "VBoxManage"),
                trigger: .onDemand,
                status: TaskStatus(state: isRunning ? .running : .disabled),
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

    /// Parse VBoxManage list output: `"Name" {UUID}` per line
    private func parseVMList(_ output: String) -> [(String, String)] {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.compactMap { line in
            // Format: "VM Name" {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
            // Verify line starts with a quote
            guard line.first == "\"" else { return nil }
            guard let nameEnd = line.firstIndex(of: "\"", offsetBy: 1),
                  let braceStart = line.firstIndex(of: "{"),
                  let braceEnd = line.firstIndex(of: "}"),
                  braceStart < braceEnd else {
                return nil
            }
            let nameStart = line.index(after: line.startIndex)
            guard nameStart < nameEnd else { return nil }
            let name = String(line[nameStart..<nameEnd])
            let uuidStart = line.index(after: braceStart)
            guard uuidStart < braceEnd else { return nil }
            let uuid = String(line[uuidStart..<braceEnd])
            return (name, uuid)
        }
    }

    private struct VMDetails {
        var cpuCount: Int?
        var memoryMB: Int?
        var osType: String?
    }

    private func getVMDetails(_ uuid: String) async throws -> VMDetails {
        guard let vboxManage = vboxManagePath else { return VMDetails() }
        let result = try await shellExecutor.execute(
            command: vboxManage,
            arguments: ["showvminfo", uuid, "--machinereadable"],
            timeout: 10.0
        )
        guard result.exitCode == 0 else { return VMDetails() }

        var details = VMDetails()
        for line in result.standardOutput.components(separatedBy: "\n") {
            if line.hasPrefix("cpus=") {
                details.cpuCount = Int(line.replacingOccurrences(of: "cpus=", with: ""))
            } else if line.hasPrefix("memory=") {
                details.memoryMB = Int(line.replacingOccurrences(of: "memory=", with: ""))
            } else if line.hasPrefix("ostype=") {
                details.osType = line.replacingOccurrences(of: "ostype=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return details
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

private extension String {
    func firstIndex(of char: Character, offsetBy offset: Int) -> String.Index? {
        guard let firstIdx = self.firstIndex(of: char) else { return nil }
        let startAfter = self.index(after: firstIdx)
        guard startAfter < self.endIndex else { return nil }
        return self[startAfter...].firstIndex(of: char)
    }
}
