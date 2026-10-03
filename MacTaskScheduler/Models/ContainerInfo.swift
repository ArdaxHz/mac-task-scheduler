//
//  ContainerInfo.swift
//  MacScheduler
//
//  Model types for Docker container metadata.
//

import Foundation

enum ContainerRuntime: String, Codable, CaseIterable {
    case dockerDesktop = "Docker Desktop"
    case orbStack = "OrbStack"
    case colima = "Colima"
    case rancher = "Rancher Desktop"
    case unknown = "Docker"
}

enum ContainerLaunchOrigin: String, Codable, CaseIterable {
    case dockerCompose = "Docker Compose"
    case boot = "Boot Container"
    case manual = "Manual"
    case dockerfile = "Dockerfile"
    case command = "Command"
}

enum DockerRestartPolicy: String, Codable, CaseIterable {
    case no = "no"
    case always = "always"
    case unlessStopped = "unless-stopped"
    case onFailure = "on-failure"

    var displayName: String {
        switch self {
        case .no: return "No"
        case .always: return "Always"
        case .unlessStopped: return "Unless Stopped"
        case .onFailure: return "On Failure"
        }
    }
}

struct ContainerInfo: Codable, Equatable {
    var containerId: String           // short 12-char ID
    var fullId: String                // full 64-char ID
    var imageName: String             // e.g. "nginx:latest"
    var launchOrigin: ContainerLaunchOrigin
    var runtime: ContainerRuntime
    var ports: [String]               // e.g. ["80/tcp -> 0.0.0.0:8080"]
    var restartPolicy: String         // "no", "always", "unless-stopped", "on-failure"
    var composeProject: String?
    var composeService: String?
    var networkMode: String?
    var createdAt: Date?
    var volumes: [String]
    var containerStatus: String       // raw status string, e.g. "Up 2 hours"
    var environmentVariables: [String: String]
    var command: [String]
    var entrypoint: [String]?
    var containerName: String
    /// All networks the container is attached to (networkMode is only the primary one).
    var networks: [String]? = nil

    /// Typed accessor for the restart policy string.
    var restartPolicyEnum: DockerRestartPolicy {
        get { DockerRestartPolicy(rawValue: restartPolicy) ?? .no }
        set { restartPolicy = newValue.rawValue }
    }
}
