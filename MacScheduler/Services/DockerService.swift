//
//  DockerService.swift
//  MacScheduler
//
//  Service for discovering and managing Docker containers.
//

import Foundation
import os

class DockerService: SchedulerService {
    static let shared = DockerService()
    let backend: SchedulerBackend = .docker

    /// Whether Docker was reachable on the last discovery attempt.
    /// Thread-safe via lock — written in discoverTasks(), read from MainActor.
    var isDockerOnline: Bool {
        _onlineLock.withLock { _isDockerOnline }
    }
    private var _isDockerOnline: Bool = false
    private let _onlineLock = OSAllocatedUnfairLock()

    private func setDockerOnline(_ value: Bool) {
        _onlineLock.withLock { _isDockerOnline = value }
    }

    private let shellExecutor = ShellExecutor.shared

    /// Candidate paths for the Docker CLI binary.
    private let dockerPaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/usr/bin/docker"
    ]

    private init() {}

    // MARK: - Docker Binary Discovery

    private var dockerPath: String? {
        dockerPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Runtime Detection

    private func detectRuntime() -> ContainerRuntime {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/OrbStack.app") {
            return .orbStack
        }
        if fm.fileExists(atPath: "/Applications/Docker.app") {
            return .dockerDesktop
        }
        if fm.fileExists(atPath: "/Applications/Rancher Desktop.app") {
            return .rancher
        }
        let home = fm.homeDirectoryForCurrentUser.path
        if fm.fileExists(atPath: "\(home)/.colima") {
            return .colima
        }
        return .unknown
    }

    // MARK: - Availability Check

    private func isDockerAvailable() async -> Bool {
        guard let docker = dockerPath else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: docker,
                arguments: ["info", "--format", "{{.ServerVersion}}"],
                timeout: 10.0
            )
            return result.exitCode == 0 && !result.standardOutput.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Input Validation

    /// Allowlist for Docker image names: alphanumeric, `.`, `-`, `_`, `/`, `:`, `@`
    static func validateImageName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_/:@"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Container name: must match `[a-zA-Z0-9][a-zA-Z0-9_.-]*`
    static func validateContainerName(_ name: String) -> Bool {
        guard !name.isEmpty else { return true } // optional
        let pattern = "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Port number must be 1-65535.
    static func validatePort(_ port: Int) -> Bool {
        port >= 1 && port <= 65535
    }

    /// Check env var name against the dangerous blocklist.
    static func validateEnvVar(_ name: String) -> Bool {
        !name.isEmpty && !PlistGenerator.isDangerousEnvVar(name) &&
        !name.contains("\0")
    }

    /// Check a string for null bytes.
    static func hasNullBytes(_ s: String) -> Bool {
        s.contains("\0")
    }

    // MARK: - SchedulerService Protocol

    func install(task: ScheduledTask) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        // Validate image name
        guard Self.validateImageName(info.imageName) else {
            throw SchedulerError.invalidTask("Invalid Docker image name")
        }

        // Validate container name if provided
        if !info.containerName.isEmpty {
            guard Self.validateContainerName(info.containerName) else {
                throw SchedulerError.invalidTask("Invalid container name. Must match [a-zA-Z0-9][a-zA-Z0-9_.-]*")
            }
        }

        // Build `docker run -d` arguments
        var args = ["run", "-d"]

        // Container name
        if !info.containerName.isEmpty {
            args.append(contentsOf: ["--name", info.containerName])
        }

        // Restart policy
        args.append(contentsOf: ["--restart", info.restartPolicy])

        // Network mode
        if let network = info.networkMode, !network.isEmpty {
            args.append(contentsOf: ["--network", network])
        }

        // Port mappings — parse from "hostPort:containerPort/protocol" format
        for portSpec in info.ports {
            guard !Self.hasNullBytes(portSpec) else { continue }
            args.append(contentsOf: ["-p", portSpec])
        }

        // Environment variables
        for (key, value) in info.environmentVariables {
            guard Self.validateEnvVar(key) else {
                throw SchedulerError.invalidTask("Dangerous or invalid environment variable: \(key)")
            }
            guard !Self.hasNullBytes(value) else {
                throw SchedulerError.invalidTask("Environment variable value contains null bytes")
            }
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Volume mounts — use raw "host:container" format
        for volume in info.volumes {
            guard !Self.hasNullBytes(volume) else { continue }
            args.append(contentsOf: ["-v", volume])
        }

        // Image
        args.append(info.imageName)

        // Command override
        if !info.command.isEmpty {
            args.append(contentsOf: info.command)
        }

        // Use 120s timeout for image pulls
        let result = try await shellExecutor.execute(
            command: docker,
            arguments: args,
            timeout: 120.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to create container: \(result.standardError)")
        }
    }

    func uninstall(task: ScheduledTask) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        // Stop if running, then remove
        if task.status.state == .running {
            let _ = try await shellExecutor.execute(
                command: docker,
                arguments: ["stop", info.containerId],
                timeout: 30.0
            )
        }

        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["rm", info.containerId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to remove container: \(result.standardError)")
        }
    }

    func enable(task: ScheduledTask) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["start", info.containerId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to start container: \(result.standardError)")
        }
    }

    func disable(task: ScheduledTask) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["stop", info.containerId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to stop container: \(result.standardError)")
        }
    }

    func runNow(task: ScheduledTask) async throws -> TaskExecutionResult {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        let startTime = Date()

        // Restart the container
        let restartResult = try await shellExecutor.execute(
            command: docker,
            arguments: ["restart", info.containerId],
            timeout: 30.0
        )

        // Fetch recent logs
        let logsResult = try await shellExecutor.execute(
            command: docker,
            arguments: ["logs", "--tail", "100", info.containerId],
            timeout: 10.0
        )

        let endTime = Date()
        return TaskExecutionResult(
            taskId: task.id,
            startTime: startTime,
            endTime: endTime,
            exitCode: restartResult.exitCode,
            standardOutput: logsResult.standardOutput,
            standardError: restartResult.exitCode != 0 ? restartResult.standardError : logsResult.standardError
        )
    }

    func isInstalled(task: ScheduledTask) async -> Bool {
        guard let docker = dockerPath, let info = task.containerInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: docker,
                arguments: ["inspect", "--format", "{{.Id}}", info.containerId],
                timeout: 10.0
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isRunning(task: ScheduledTask) async -> Bool {
        guard let docker = dockerPath, let info = task.containerInfo else { return false }
        do {
            let result = try await shellExecutor.execute(
                command: docker,
                arguments: ["inspect", "--format", "{{.State.Running}}", info.containerId],
                timeout: 10.0
            )
            return result.exitCode == 0 && result.standardOutput == "true"
        } catch {
            return false
        }
    }

    // MARK: - Docker-Specific Operations

    /// Update only the restart policy of a running container (no recreation needed).
    func updateRestartPolicy(task: ScheduledTask, policy: DockerRestartPolicy) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["update", "--restart=\(policy.rawValue)", info.containerId],
            timeout: 30.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to update restart policy: \(result.standardError)")
        }
    }

    /// Recreate a container: stop + remove + install with new settings.
    func recreateContainer(oldTask: ScheduledTask, newTask: ScheduledTask) async throws {
        // Stop and remove the old container
        try await uninstall(task: oldTask)
        // Create a new container with updated settings
        try await install(task: newTask)
    }

    /// Remove a container with optional cascade (volumes, image, compose down).
    func removeWithCascade(task: ScheduledTask, removeVolumes: Bool, removeImage: Bool) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard let info = task.containerInfo else {
            throw SchedulerError.invalidTask("Not a Docker container")
        }

        // Stop if running
        if task.status.state == .running {
            let _ = try await shellExecutor.execute(
                command: docker,
                arguments: ["stop", info.containerId],
                timeout: 30.0
            )
        }

        // Remove container (optionally with volumes)
        var rmArgs = ["rm"]
        if removeVolumes { rmArgs.append("-v") }
        rmArgs.append(info.containerId)

        let rmResult = try await shellExecutor.execute(
            command: docker,
            arguments: rmArgs,
            timeout: 30.0
        )
        if rmResult.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to remove container: \(rmResult.standardError)")
        }

        // Optionally remove the image
        if removeImage {
            let rmiResult = try await shellExecutor.execute(
                command: docker,
                arguments: ["rmi", info.imageName],
                timeout: 60.0
            )
            if rmiResult.exitCode != 0 {
                // Image removal failure is non-fatal (might be used by other containers)
                // We don't throw here — the container itself was already removed
            }
        }
    }

    /// Docker Compose down for a project.
    func composeDown(projectName: String, removeVolumes: Bool) async throws {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard !projectName.isEmpty, !Self.hasNullBytes(projectName) else {
            throw SchedulerError.invalidTask("Invalid Compose project name")
        }

        var args = ["compose", "-p", projectName, "down"]
        if removeVolumes { args.append("-v") }

        let result = try await shellExecutor.execute(
            command: docker,
            arguments: args,
            timeout: 120.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to run compose down: \(result.standardError)")
        }
    }

    /// Determine if recreation is needed (anything other than restart policy changed).
    static func needsRecreation(old: ContainerInfo, new: ContainerInfo) -> Bool {
        old.imageName != new.imageName ||
        old.ports != new.ports ||
        old.environmentVariables != new.environmentVariables ||
        old.volumes != new.volumes ||
        old.networkMode != new.networkMode ||
        old.command != new.command ||
        old.containerName != new.containerName
    }

    // MARK: - Discovery

    func discoverTasks() async throws -> [ScheduledTask] {
        guard let docker = dockerPath else {
            setDockerOnline(false)
            return await DockerCacheService.shared.load()
        }
        guard await isDockerAvailable() else {
            setDockerOnline(false)
            return await DockerCacheService.shared.load()
        }
        setDockerOnline(true)

        let runtime = detectRuntime()

        // List all containers (running + stopped) in JSON format
        let listResult = try await shellExecutor.execute(
            command: docker,
            arguments: ["ps", "-a", "--no-trunc", "--format", "{{json .}}"],
            timeout: 15.0
        )

        if listResult.exitCode != 0 {
            return []
        }

        let lines = listResult.standardOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.isEmpty { return [] }

        // Parse each container line
        var containerIds: [String] = []
        var basicInfo: [String: DockerPsEntry] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let entry = try JSONDecoder().decode(DockerPsEntry.self, from: data)
                containerIds.append(entry.ID)
                basicInfo[entry.ID] = entry
            } catch {
                continue
            }
        }

        if containerIds.isEmpty { return [] }

        // Batch inspect for full details
        var inspectArgs = ["inspect"]
        inspectArgs.append(contentsOf: containerIds)
        let inspectResult = try await shellExecutor.execute(
            command: docker,
            arguments: inspectArgs,
            timeout: 30.0
        )

        guard inspectResult.exitCode == 0,
              let inspectData = inspectResult.standardOutput.data(using: .utf8) else {
            return []
        }

        let inspections: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: inspectData) as? [[String: Any]] else {
                return []
            }
            inspections = parsed
        } catch {
            return []
        }

        // Build ScheduledTask for each container
        var tasks: [ScheduledTask] = []
        for inspection in inspections {
            guard let fullId = inspection["Id"] as? String else { continue }
            let shortId = String(fullId.prefix(12))

            let config = inspection["Config"] as? [String: Any] ?? [:]
            let state = inspection["State"] as? [String: Any] ?? [:]
            let hostConfig = inspection["HostConfig"] as? [String: Any] ?? [:]
            let networkSettings = inspection["NetworkSettings"] as? [String: Any] ?? [:]

            // Container name (strip leading /)
            let rawName = (inspection["Name"] as? String) ?? shortId
            let containerName = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName

            // Image
            let imageName = (config["Image"] as? String) ?? "unknown"

            // Labels
            let labels = (config["Labels"] as? [String: String]) ?? [:]

            // Restart policy
            let restartPolicyDict = hostConfig["RestartPolicy"] as? [String: Any] ?? [:]
            let restartPolicy = (restartPolicyDict["Name"] as? String) ?? "no"

            // Launch origin classification
            let launchOrigin = classifyLaunchOrigin(
                labels: labels,
                restartPolicy: restartPolicy,
                config: config,
                imageName: imageName
            )

            // Compose info
            let composeProject = labels["com.docker.compose.project"]
            let composeService = labels["com.docker.compose.service"]

            // Ports
            let ports = parsePorts(networkSettings: networkSettings)

            // Volumes/Mounts
            let mounts = (inspection["Mounts"] as? [[String: Any]]) ?? []
            let volumes = mounts.compactMap { mount -> String? in
                let source = (mount["Source"] as? String) ?? ""
                let dest = (mount["Destination"] as? String) ?? ""
                if source.isEmpty && dest.isEmpty { return nil }
                return "\(source):\(dest)"
            }

            // Network mode
            let networkMode = hostConfig["NetworkMode"] as? String

            // Created date
            let createdString = inspection["Created"] as? String
            let createdAt = createdString.flatMap { parseDockerDate($0) }

            // State mapping
            let stateStr = (state["Status"] as? String) ?? "unknown"
            let exitCode = (state["ExitCode"] as? Int) ?? 0
            let taskState = mapContainerState(status: stateStr, exitCode: exitCode)

            // Status string from ps output
            let psEntry = basicInfo[fullId]
            let containerStatus = psEntry?.Status ?? stateStr

            // Process start time for running containers
            let startedAtStr = state["StartedAt"] as? String
            let processStartTime = startedAtStr.flatMap { parseDockerDate($0) }

            // Container command and entrypoint
            let cmdArray = (config["Cmd"] as? [String]) ?? []
            let entrypointArray = config["Entrypoint"] as? [String]
            let cmd = cmdArray.joined(separator: " ")

            // Environment variables from Config.Env (format: "KEY=VALUE")
            let envArray = (config["Env"] as? [String]) ?? []
            var envVars: [String: String] = [:]
            for entry in envArray {
                if let eqIdx = entry.firstIndex(of: "=") {
                    let key = String(entry[entry.startIndex..<eqIdx])
                    let value = String(entry[entry.index(after: eqIdx)...])
                    envVars[key] = value
                }
            }

            // Build display name
            let displayName: String
            if let project = composeProject, let service = composeService {
                displayName = "\(project)/\(service)"
            } else {
                displayName = containerName
            }

            let containerInfo = ContainerInfo(
                containerId: shortId,
                fullId: fullId,
                imageName: imageName,
                launchOrigin: launchOrigin,
                runtime: runtime,
                ports: ports,
                restartPolicy: restartPolicy,
                composeProject: composeProject,
                composeService: composeService,
                networkMode: networkMode,
                createdAt: createdAt,
                volumes: volumes,
                containerStatus: containerStatus,
                environmentVariables: envVars,
                command: cmdArray,
                entrypoint: entrypointArray,
                containerName: containerName
            )

            let label = "docker.\(containerName)"

            var task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(label),
                name: displayName,
                description: imageName,
                backend: .docker,
                action: TaskAction(
                    type: .shellScript,
                    path: imageName,
                    scriptContent: cmd.isEmpty ? nil : cmd
                ),
                trigger: (restartPolicy == "always" || restartPolicy == "unless-stopped") ? .atStartup : .onDemand,
                status: TaskStatus(state: taskState),
                createdAt: createdAt ?? Date(),
                modifiedAt: Date(),
                launchdLabel: label,
                isReadOnly: false,
                location: .userAgent,
                containerInfo: containerInfo
            )

            if taskState == .running, let start = processStartTime {
                task.status.processStartTime = start
            }

            if taskState == .error {
                task.status.lastExitStatus = Int32(exitCode)
            }

            tasks.append(task)
        }

        // Cache discovered containers for offline display
        await DockerCacheService.shared.save(tasks: tasks)

        return tasks
    }

    // MARK: - Docker Inspection

    /// Inspect a Docker image by name.
    func inspectImage(_ imageName: String) async throws -> String {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard DockerService.validateImageName(imageName) else {
            throw SchedulerError.invalidTask("Invalid image name")
        }
        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["image", "inspect", imageName],
            timeout: 15.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to inspect image: \(result.standardError)")
        }
        return result.standardOutput
    }

    /// Get Docker Compose config for a project.
    func composeConfig(projectName: String) async throws -> String {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard !projectName.isEmpty, !Self.hasNullBytes(projectName) else {
            throw SchedulerError.invalidTask("Invalid Compose project name")
        }
        let result = try await shellExecutor.execute(
            command: docker,
            arguments: ["compose", "-p", projectName, "config"],
            timeout: 15.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to get compose config: \(result.standardError)")
        }
        return result.standardOutput
    }

    /// Inspect Docker volumes by name.
    func inspectVolumes(_ volumeNames: [String]) async throws -> String {
        guard let docker = dockerPath else {
            throw SchedulerError.dockerNotAvailable("Docker CLI not found")
        }
        guard !volumeNames.isEmpty else {
            throw SchedulerError.invalidTask("No volume names provided")
        }
        // Filter out volume names with null bytes
        let safeNames = volumeNames.filter { !Self.hasNullBytes($0) && !$0.isEmpty }
        guard !safeNames.isEmpty else {
            throw SchedulerError.invalidTask("No valid volume names provided")
        }
        var args = ["volume", "inspect"]
        args.append(contentsOf: safeNames)
        let result = try await shellExecutor.execute(
            command: docker,
            arguments: args,
            timeout: 15.0
        )
        if result.exitCode != 0 {
            throw SchedulerError.dockerCommandFailed("Failed to inspect volumes: \(result.standardError)")
        }
        return result.standardOutput
    }

    // MARK: - Helpers

    private func classifyLaunchOrigin(
        labels: [String: String],
        restartPolicy: String,
        config: [String: Any],
        imageName: String
    ) -> ContainerLaunchOrigin {
        // 1. Docker Compose
        if labels["com.docker.compose.project"] != nil {
            return .dockerCompose
        }

        // 2. Boot/auto-start container
        if restartPolicy == "always" || restartPolicy == "unless-stopped" {
            return .boot
        }

        // 3. Interactive/manual (TTY + stdin)
        let tty = (config["Tty"] as? Bool) ?? false
        let openStdin = (config["OpenStdin"] as? Bool) ?? false
        if tty && openStdin {
            return .manual
        }

        // 4. Dockerfile-built (no registry prefix or localhost)
        if !imageName.contains("/") || imageName.hasPrefix("localhost/") {
            return .dockerfile
        }

        // 5. Default
        return .command
    }

    private func mapContainerState(status: String, exitCode: Int) -> TaskState {
        switch status.lowercased() {
        case "running":
            return .running
        case "exited":
            return exitCode == 0 ? .disabled : .error
        case "paused":
            return .disabled
        case "restarting":
            return .running
        case "created":
            return .disabled
        case "dead":
            return .error
        default:
            return .disabled
        }
    }

    private func parsePorts(networkSettings: [String: Any]) -> [String] {
        guard let portsDict = networkSettings["Ports"] as? [String: Any] else { return [] }
        var result: [String] = []
        for (containerPort, bindings) in portsDict {
            if let bindingArray = bindings as? [[String: String]] {
                for binding in bindingArray {
                    let hostIp = binding["HostIp"] ?? "0.0.0.0"
                    let hostPort = binding["HostPort"] ?? ""
                    if !hostPort.isEmpty {
                        result.append("\(containerPort) -> \(hostIp):\(hostPort)")
                    }
                }
            } else {
                result.append(containerPort)
            }
        }
        return result.sorted()
    }

    // Cached date formatters to avoid repeated allocation during discovery
    private static let dockerDateFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dockerDateFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseDockerDate(_ dateString: String) -> Date? {
        // Docker uses ISO 8601 with nanoseconds: 2024-01-15T10:30:00.123456789Z
        if let date = Self.dockerDateFormatterFractional.date(from: dateString) {
            return date
        }
        // Fallback without fractional seconds
        return Self.dockerDateFormatterBasic.date(from: dateString)
    }
}

// MARK: - Docker PS JSON Entry

private struct DockerPsEntry: Decodable {
    let ID: String
    let Status: String

    enum CodingKeys: String, CodingKey {
        case ID
        case Status
    }
}
