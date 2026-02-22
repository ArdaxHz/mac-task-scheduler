//
//  VMwareFusionService.swift
//  MacScheduler
//
//  Service for discovering and managing VMware Fusion virtual machines.
//

import Foundation

class VMwareFusionService: SchedulerService {
    static let shared = VMwareFusionService()
    let backend: SchedulerBackend = .vmwareFusion

    private let shellExecutor = ShellExecutor.shared

    private let vmrunPaths = [
        "/Applications/VMware Fusion.app/Contents/Library/vmrun",
        "/usr/local/bin/vmrun"
    ]

    private init() {}

    private var vmrunPath: String? {
        vmrunPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Path Validation

    /// Validate that a .vmx path is safe (no path traversal, no null bytes).
    private func validateVMXPath(_ path: String) -> Bool {
        guard !path.contains("\0") else { return false }
        guard path.hasSuffix(".vmx") else { return false }
        // Resolve symlinks and check for path traversal
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.contains("..") else { return false }
        return true
    }

    // MARK: - SchedulerService Protocol

    func install(task: ScheduledTask) async throws {
        throw SchedulerError.vmOperationNotSupported("Cannot create VMs through this app")
    }

    func uninstall(task: ScheduledTask) async throws {
        throw SchedulerError.vmOperationNotSupported("Cannot delete VMs through this app")
    }

    func enable(task: ScheduledTask) async throws {
        guard let vmrun = vmrunPath else {
            throw SchedulerError.vmNotAvailable("vmrun not found")
        }
        guard let info = task.vmInfo else {
            throw SchedulerError.invalidTask("Not a VMware Fusion VM")
        }
        guard validateVMXPath(info.vmId) else {
            throw SchedulerError.invalidTask("Invalid .vmx path")
        }
        let result = try await shellExecutor.execute(
            command: vmrun,
            arguments: ["start", info.vmId, "nogui"],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.vmCommandFailed("Failed to start VM: \(result.standardError)")
        }
    }

    func disable(task: ScheduledTask) async throws {
        guard let vmrun = vmrunPath else {
            throw SchedulerError.vmNotAvailable("vmrun not found")
        }
        guard let info = task.vmInfo else {
            throw SchedulerError.invalidTask("Not a VMware Fusion VM")
        }
        guard validateVMXPath(info.vmId) else {
            throw SchedulerError.invalidTask("Invalid .vmx path")
        }
        let result = try await shellExecutor.execute(
            command: vmrun,
            arguments: ["stop", info.vmId, "soft"],
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
        guard let info = task.vmInfo else { return false }
        return FileManager.default.fileExists(atPath: info.vmId)
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        guard let vmrun = vmrunPath, let info = task.vmInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: vmrun,
                arguments: ["list"],
                timeout: 10.0
            )
            return result.exitCode == 0 && result.standardOutput.contains(info.vmId)
        } catch {
            return false
        }
    }

    // MARK: - Discovery

    func discoverTasks() async throws -> [ScheduledTask] {
        guard let vmrun = vmrunPath else { return [] }

        // Get list of running VMs
        let runningResult = try await shellExecutor.execute(
            command: vmrun,
            arguments: ["list"],
            timeout: 15.0
        )
        var runningVMXPaths = Set<String>()
        if runningResult.exitCode == 0 {
            let lines = runningResult.standardOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
            // First line is "Total running VMs: N", skip it
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(".vmx") {
                    runningVMXPaths.insert(trimmed)
                }
            }
        }

        // Scan for all .vmwarevm bundles in ~/Virtual Machines.localized/
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vmDir = "\(home)/Virtual Machines.localized"
        var allVMXPaths: [String] = []

        let fm = FileManager.default
        if fm.fileExists(atPath: vmDir),
           let bundles = try? fm.contentsOfDirectory(atPath: vmDir) {
            for bundle in bundles where bundle.hasSuffix(".vmwarevm") {
                let bundlePath = "\(vmDir)/\(bundle)"
                if let contents = try? fm.contentsOfDirectory(atPath: bundlePath) {
                    for file in contents where file.hasSuffix(".vmx") {
                        let vmxPath = "\(bundlePath)/\(file)"
                        if validateVMXPath(vmxPath) {
                            allVMXPaths.append(vmxPath)
                        }
                    }
                }
            }
        }

        // Also include running VMs not in the standard directory
        for vmxPath in runningVMXPaths {
            if !allVMXPaths.contains(vmxPath) && validateVMXPath(vmxPath) {
                allVMXPaths.append(vmxPath)
            }
        }

        var tasks: [ScheduledTask] = []
        for vmxPath in allVMXPaths {
            let displayName = parseDisplayName(from: vmxPath) ?? (vmxPath as NSString).lastPathComponent
            let isRunning = runningVMXPaths.contains(vmxPath)

            let sanitizedName = sanitizeVMName(displayName)
            let label = "vmware.\(sanitizedName)"

            let vmInfo = VMInfo(
                vmId: vmxPath,
                vmName: displayName,
                vmState: isRunning ? "running" : "stopped",
                backend: .vmwareFusion,
                osType: nil
            )

            let task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(label),
                name: displayName,
                description: "VMware Fusion VM",
                backend: .vmwareFusion,
                action: TaskAction(type: .executable, path: "vmrun"),
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

    /// Parse displayName from .vmx file (bounded to 256 KB to avoid memory issues on large files).
    private func parseDisplayName(from vmxPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: vmxPath) else { return nil }
        defer { handle.closeFile() }
        let maxBytes = 256 * 1024 // 256 KB — .vmx files are typically < 10 KB
        let data = handle.readData(ofLength: maxBytes)
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("displayName") {
                // Format: displayName = "My VM"
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    var value = String(trimmed[trimmed.index(after: eqIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    // Strip surrounding quotes
                    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
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
