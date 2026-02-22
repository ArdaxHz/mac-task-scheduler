//
//  DockerCacheService.swift
//  MacScheduler
//
//  Persists Docker container list for offline display when Docker is not running.
//

import Foundation

actor DockerCacheService {
    static let shared = DockerCacheService()

    private let maxCachedContainers = 1000

    private var cachedTasks: [CachedContainer] = []

    private init() {
        cachedTasks = loadFromDisk()
    }

    // MARK: - Types

    struct CachedContainer: Codable {
        let name: String
        let label: String
        let containerInfo: ContainerInfo
        let statusState: String
        let createdAt: Date
    }

    // MARK: - Public API

    /// Save discovered Docker tasks to the cache file.
    func save(tasks: [ScheduledTask]) {
        let containers = Array(tasks.prefix(maxCachedContainers)).compactMap { task -> CachedContainer? in
            guard let info = task.containerInfo else { return nil }
            return CachedContainer(
                name: task.name,
                label: task.launchdLabel,
                containerInfo: info,
                statusState: task.status.state.rawValue,
                createdAt: task.createdAt
            )
        }
        cachedTasks = containers
        writeToDisk(containers)
    }

    /// Load cached Docker tasks for offline display. Returns tasks with isStale = true.
    func load() -> [ScheduledTask] {
        return cachedTasks.compactMap { cached -> ScheduledTask? in
            let taskState = TaskState(rawValue: cached.statusState) ?? .disabled

            var task = ScheduledTask(
                id: ScheduledTask.uuidFromLabel(cached.label),
                name: cached.name,
                description: cached.containerInfo.imageName,
                backend: .docker,
                action: TaskAction(
                    type: .shellScript,
                    path: cached.containerInfo.imageName,
                    scriptContent: cached.containerInfo.command.isEmpty ? nil : cached.containerInfo.command.joined(separator: " ")
                ),
                trigger: (cached.containerInfo.restartPolicy == "always" || cached.containerInfo.restartPolicy == "unless-stopped") ? .atStartup : .onDemand,
                status: TaskStatus(state: taskState),
                createdAt: cached.createdAt,
                modifiedAt: Date(),
                launchdLabel: cached.label,
                isReadOnly: true,
                location: .userAgent,
                containerInfo: cached.containerInfo
            )
            task.isStale = true
            return task
        }
    }

    // MARK: - Persistence

    private var cacheFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("MacScheduler")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("docker-cache.json")
    }

    private func loadFromDisk() -> [CachedContainer] {
        guard let url = cacheFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CachedContainer].self, from: data)
        } catch {
            return []
        }
    }

    private func writeToDisk(_ containers: [CachedContainer]) {
        guard let url = cacheFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(containers)
            try data.write(to: url, options: .atomic)
            // Set restrictive permissions — cache may contain env var secrets
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Non-fatal: cache write failure doesn't affect app operation
        }
    }
}
