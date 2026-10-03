//
//  DockerEditorViewModel.swift
//  MacScheduler
//
//  ViewModel for Docker container create/edit form.
//

import Foundation
import SwiftUI

@MainActor
class DockerEditorViewModel: ObservableObject {
    @Published var imageName = ""
    @Published var containerName = ""
    @Published var portMappings: [PortMapping] = []
    @Published var envVars: [EnvVar] = []
    @Published var volumeMounts: [VolumeMount] = []
    @Published var restartPolicy: DockerRestartPolicy = .no
    @Published var networkMode = ""
    @Published var commandOverride = ""

    @Published var showValidationErrors = false
    @Published var validationErrors: [String] = []

    var isEditing = false
    private var originalTask: ScheduledTask?

    var title: String {
        isEditing ? "Edit Container" : "New Docker Container"
    }

    // MARK: - Inner Types

    struct PortMapping: Identifiable {
        let id = UUID()
        var hostPort: String = ""
        var containerPort: String = ""
        var proto: String = "tcp" // "tcp" or "udp"
    }

    struct EnvVar: Identifiable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
    }

    struct VolumeMount: Identifiable {
        let id = UUID()
        var hostPath: String = ""
        var containerPath: String = ""
    }

    // MARK: - Load / Reset

    func loadTask(_ task: ScheduledTask) {
        isEditing = true
        originalTask = task

        guard let info = task.containerInfo else { return }

        imageName = info.imageName
        containerName = info.containerName
        restartPolicy = info.restartPolicyEnum
        networkMode = info.networkMode ?? ""
        commandOverride = ShellWords.join(info.command)

        // Parse port mappings from discovery format "containerPort/proto -> hostIp:hostPort"
        // or install format "hostPort:containerPort/proto"
        portMappings = info.ports.compactMap { portStr -> PortMapping? in
            var mapping = PortMapping()
            if portStr.contains(" -> ") {
                // Discovery format: "80/tcp -> 0.0.0.0:8080"
                let parts = portStr.components(separatedBy: " -> ")
                guard parts.count == 2 else { return nil }
                let containerPart = parts[0] // "80/tcp"
                let hostPart = parts[1]       // "0.0.0.0:8080"

                let containerPieces = containerPart.components(separatedBy: "/")
                mapping.containerPort = containerPieces[0]
                if containerPieces.count > 1 { mapping.proto = containerPieces[1] }

                if let colonIdx = hostPart.lastIndex(of: ":") {
                    mapping.hostPort = String(hostPart[hostPart.index(after: colonIdx)...])
                } else {
                    mapping.hostPort = hostPart
                }
            } else if portStr.contains(":") {
                // Install format: "8080:80/tcp"
                let protoParts = portStr.components(separatedBy: "/")
                let portPart = protoParts[0]
                if protoParts.count > 1 { mapping.proto = protoParts[1] }

                let colonParts = portPart.components(separatedBy: ":")
                if colonParts.count == 2 {
                    mapping.hostPort = colonParts[0]
                    mapping.containerPort = colonParts[1]
                }
            }
            return mapping
        }

        // Environment variables
        envVars = info.environmentVariables.map { key, value in
            EnvVar(key: key, value: value)
        }.sorted { $0.key < $1.key }

        // Volume mounts — format "hostPath:containerPath"
        volumeMounts = info.volumes.compactMap { vol -> VolumeMount? in
            let parts = vol.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }
            return VolumeMount(hostPath: parts[0], containerPath: parts[1])
        }
    }

    func reset() {
        isEditing = false
        originalTask = nil
        imageName = ""
        containerName = ""
        portMappings = []
        envVars = []
        volumeMounts = []
        restartPolicy = .no
        networkMode = ""
        commandOverride = ""
    }

    // MARK: - Env File Import

    /// Import environment variables from a .env file.
    /// Parses KEY=value lines, ignores comments and blank lines,
    /// strips surrounding quotes, checks dangerous env var blocklist.
    func importEnvFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() || true else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        let lines = contents.components(separatedBy: .newlines)
        var imported = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Parse KEY=value
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\0", with: "")
            guard !key.isEmpty else { continue }

            var value = String(trimmed[trimmed.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\0", with: "")

            // Strip surrounding quotes (single or double)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                if value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
            }

            // Check dangerous env var blocklist
            if PlistGenerator.isDangerousEnvVar(key) { continue }

            // Merge: update existing key or append new
            if let existingIdx = envVars.firstIndex(where: { $0.key == key }) {
                envVars[existingIdx].value = value
            } else {
                envVars.append(EnvVar(key: key, value: value))
                imported += 1
            }

            // Cap at 500 vars
            if envVars.count >= 500 { break }
        }
    }

    // MARK: - Validation

    func validate() -> Bool {
        validationErrors = []

        // Image required
        let trimmedImage = imageName.trimmingCharacters(in: .whitespaces)
        if trimmedImage.isEmpty {
            validationErrors.append("Docker image name is required")
        } else if !DockerService.validateImageName(trimmedImage) {
            validationErrors.append("Invalid image name. Allowed: alphanumeric, '.', '-', '_', '/', ':', '@'")
        }

        // Container name (optional but validated)
        let trimmedName = containerName.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty && !DockerService.validateContainerName(trimmedName) {
            validationErrors.append("Invalid container name. Must start with alphanumeric, then alphanumeric + '_', '.', '-'")
        }

        // Ports
        for (i, mapping) in portMappings.enumerated() {
            let host = mapping.hostPort.trimmingCharacters(in: .whitespaces)
            let container = mapping.containerPort.trimmingCharacters(in: .whitespaces)
            if host.isEmpty && container.isEmpty { continue } // skip empty rows

            if let port = Int(host) {
                if !DockerService.validatePort(port) {
                    validationErrors.append("Port mapping #\(i+1): host port must be 1-65535")
                }
            } else if !host.isEmpty {
                validationErrors.append("Port mapping #\(i+1): host port must be a number")
            }

            if let port = Int(container) {
                if !DockerService.validatePort(port) {
                    validationErrors.append("Port mapping #\(i+1): container port must be 1-65535")
                }
            } else if !container.isEmpty {
                validationErrors.append("Port mapping #\(i+1): container port must be a number")
            }
        }

        // Env vars
        for (i, env) in envVars.enumerated() {
            let key = env.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty && env.value.isEmpty { continue } // skip empty rows
            if key.isEmpty {
                validationErrors.append("Environment variable #\(i+1): key is required")
            } else if PlistGenerator.isDangerousEnvVar(key) {
                validationErrors.append("Environment variable '\(key)' is blocked for security reasons")
            }
            if key.contains("\0") || env.value.contains("\0") {
                validationErrors.append("Environment variable #\(i+1): null bytes not allowed")
            }
        }

        // Null byte checks
        if imageName.contains("\0") { validationErrors.append("Image name contains null bytes") }
        if containerName.contains("\0") { validationErrors.append("Container name contains null bytes") }
        if commandOverride.contains("\0") { validationErrors.append("Command contains null bytes") }

        if !validationErrors.isEmpty {
            showValidationErrors = true
            return false
        }
        return true
    }

    // MARK: - Build Task

    func buildTask() -> ScheduledTask {
        let trimmedImage = imageName.trimmingCharacters(in: .whitespaces)
        let trimmedName = containerName.trimmingCharacters(in: .whitespaces)

        // Build port specs in "hostPort:containerPort/proto" format for docker run -p
        let portSpecs = portMappings.compactMap { mapping -> String? in
            let host = mapping.hostPort.trimmingCharacters(in: .whitespaces)
            let container = mapping.containerPort.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty || !container.isEmpty else { return nil }
            let proto = mapping.proto.isEmpty ? "tcp" : mapping.proto
            if !host.isEmpty && !container.isEmpty {
                return "\(host):\(container)/\(proto)"
            } else if !container.isEmpty {
                return "\(container)/\(proto)"
            }
            return nil
        }

        // Build env var dictionary
        var envDict: [String: String] = [:]
        for env in envVars {
            let key = env.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                envDict[key] = env.value
            }
        }

        // Build volume specs in "hostPath:containerPath" format
        let volumeSpecs = volumeMounts.compactMap { mount -> String? in
            let host = mount.hostPath.trimmingCharacters(in: .whitespaces)
            let container = mount.containerPath.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty && !container.isEmpty else { return nil }
            return "\(host):\(container)"
        }

        // Parse command (quote-aware, so `sh -c 'a b'` stays three arguments)
        let cmdParts = ShellWords.split(commandOverride)

        let displayName = trimmedName.isEmpty ? trimmedImage : trimmedName
        let label = "docker.\(trimmedName.isEmpty ? trimmedImage.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") : trimmedName)"

        let containerInfo = ContainerInfo(
            containerId: originalTask?.containerInfo?.containerId ?? "",
            fullId: originalTask?.containerInfo?.fullId ?? "",
            imageName: trimmedImage,
            launchOrigin: originalTask?.containerInfo?.launchOrigin ?? .command,
            runtime: originalTask?.containerInfo?.runtime ?? .unknown,
            ports: portSpecs,
            restartPolicy: restartPolicy.rawValue,
            composeProject: originalTask?.containerInfo?.composeProject,
            composeService: originalTask?.containerInfo?.composeService,
            networkMode: networkMode.isEmpty ? nil : networkMode,
            createdAt: originalTask?.containerInfo?.createdAt,
            volumes: volumeSpecs,
            containerStatus: originalTask?.containerInfo?.containerStatus ?? "",
            environmentVariables: envDict,
            command: cmdParts,
            // Keep the original entrypoint only for the same image — a new image brings its own
            entrypoint: originalTask?.containerInfo?.imageName == trimmedImage ? originalTask?.containerInfo?.entrypoint : nil,
            containerName: trimmedName
        )

        let taskId = originalTask?.id ?? ScheduledTask.uuidFromLabel(label)
        let policy = restartPolicy
        let trigger: TaskTrigger = (policy == .always || policy == .unlessStopped) ? .atStartup : .onDemand

        return ScheduledTask(
            id: taskId,
            name: displayName,
            description: trimmedImage,
            backend: .docker,
            action: TaskAction(
                type: .shellScript,
                path: trimmedImage,
                scriptContent: cmdParts.isEmpty ? nil : cmdParts.joined(separator: " ")
            ),
            trigger: trigger,
            status: originalTask?.status ?? TaskStatus(state: .disabled),
            createdAt: originalTask?.createdAt ?? Date(),
            modifiedAt: Date(),
            launchdLabel: originalTask?.launchdLabel ?? label,
            isReadOnly: false,
            location: .userAgent,
            containerInfo: containerInfo
        )
    }

    // MARK: - Recreation Check

    /// Returns true if editing requires container recreation (anything besides restart policy changed).
    var requiresRecreation: Bool {
        guard isEditing, let original = originalTask, let oldInfo = original.containerInfo else {
            return false
        }
        let newTask = buildTask()
        guard let newInfo = newTask.containerInfo else { return false }
        return DockerService.needsRecreation(old: oldInfo, new: newInfo)
    }
}
