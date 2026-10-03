//
//  TaskVersionService.swift
//  MacScheduler
//
//  Service for managing task version history snapshots.
//  Saves plist/cron content before edits and deletes.
//

import Foundation

actor TaskVersionService {
    static let shared = TaskVersionService()

    private let fileManager = FileManager.default
    private var snapshots: [TaskSnapshot] = []
    private let maxSnapshotsPerTask = 50
    private let maxTotalSnapshots = 500

    private var pendingSave: Task<Void, Never>?

    private var appSupportDir: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("MacTaskScheduler")
    }

    private var indexFileURL: URL? {
        appSupportDir?.appendingPathComponent("edit-history.json")
    }

    private var snapshotsBaseDir: URL? {
        appSupportDir?.appendingPathComponent("Snapshots")
    }

    private init() {
        Task { await loadIndex() }
    }

    // MARK: - Public API

    func saveSnapshot(for task: ScheduledTask, reason: TaskSnapshot.SnapshotReason, newLabel: String? = nil) async {
        let content: String?

        switch task.backend {
        case .launchd:
            content = readPlistContent(for: task)
        case .cron:
            content = await readCronContent(for: task)
        default:
            return // Only launchd and cron tasks have restorable config
        }

        guard let content = content, !content.isEmpty else { return }
        writeSnapshot(content: content, label: task.launchdLabel, name: task.name,
                      reason: reason, backend: task.backend.rawValue, newLabel: newLabel,
                      location: task.backend == .launchd ? task.location : nil)
    }

    /// Save a snapshot with pre-read content. Use this when the caller already has the file content
    /// to avoid blocking the caller on actor-internal file reads.
    func saveSnapshotWithContent(_ content: String, label: String, name: String,
                                 reason: TaskSnapshot.SnapshotReason, backend: String,
                                 newLabel: String? = nil, location: TaskLocation? = nil) {
        guard !content.isEmpty else { return }
        writeSnapshot(content: content, label: label, name: name,
                      reason: reason, backend: backend, newLabel: newLabel, location: location)
    }

    private func writeSnapshot(content: String, label: String, name: String,
                                reason: TaskSnapshot.SnapshotReason, backend: String,
                                newLabel: String?, location: TaskLocation?) {
        let sanitizedLabel = sanitizeForFilename(label)
        guard !sanitizedLabel.isEmpty else { return }

        let ext = backend == SchedulerBackend.cron.rawValue ? "cron" : "plist"
        let timestamp = compactTimestamp()
        let fileName = "\(timestamp)-\(reason.rawValue).\(ext)"

        guard let baseDir = snapshotsBaseDir else { return }
        let snapshotsDir = baseDir.appendingPathComponent(sanitizedLabel)

        // Validate the resolved path is within snapshots base dir
        let resolvedDir = snapshotsDir.resolvingSymlinksInPath().path
        let resolvedBase = baseDir.resolvingSymlinksInPath().path
        guard resolvedDir.hasPrefix(resolvedBase + "/") || resolvedDir == resolvedBase else { return }

        do {
            try fileManager.createDirectory(at: snapshotsDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])

            let filePath = snapshotsDir.appendingPathComponent(fileName)

            // Verify file path also resolves within snapshots dir
            let resolvedFile = filePath.resolvingSymlinksInPath().path
            guard resolvedFile.hasPrefix(resolvedBase + "/") else { return }

            let data = Data(content.utf8)
            guard fileManager.createFile(atPath: filePath.path, contents: data,
                                         attributes: [.posixPermissions: 0o600]) else {
                return
            }

            let snapshot = TaskSnapshot(
                taskLabel: label,
                taskName: name,
                reason: reason,
                backend: backend,
                snapshotFileName: fileName,
                newLabel: newLabel,
                location: location
            )
            snapshots.insert(snapshot, at: 0)

            pruneSnapshots()
            scheduleSave()
        } catch {
            print("TaskVersionService: Failed to save snapshot: \(error)")
        }
    }

    func getSnapshots(for label: String) -> [TaskSnapshot] {
        snapshots
            .filter { $0.taskLabel == label }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func getDeletedSnapshots() -> [TaskSnapshot] {
        // Return the most recent beforeDelete snapshot per label
        var seen = Set<String>()
        var result: [TaskSnapshot] = []
        let deletedOnly = snapshots
            .filter { $0.reason == .beforeDelete }
            .sorted { $0.timestamp > $1.timestamp }
        for snapshot in deletedOnly {
            if !seen.contains(snapshot.taskLabel) {
                seen.insert(snapshot.taskLabel)
                result.append(snapshot)
            }
        }
        return result
    }

    /// Max snapshot file size to read (1 MB). Prevents OOM from tampered files.
    private let maxSnapshotReadSize = 1_048_576

    func readSnapshotContent(_ snapshot: TaskSnapshot) -> String? {
        let sanitizedLabel = sanitizeForFilename(snapshot.taskLabel)
        guard !sanitizedLabel.isEmpty,
              let safeFileName = sanitizeSnapshotFilename(snapshot.snapshotFileName),
              let baseDir = snapshotsBaseDir else { return nil }

        let filePath = baseDir.appendingPathComponent(sanitizedLabel).appendingPathComponent(safeFileName)

        // Validate path is within snapshots dir (resolve symlinks)
        let resolvedPath = filePath.resolvingSymlinksInPath().path
        let resolvedBase = baseDir.resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(resolvedBase + "/") else { return nil }

        // Bounded read to prevent OOM from tampered/replaced files
        guard let handle = FileHandle(forReadingAtPath: filePath.path) else { return nil }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: maxSnapshotReadSize)
        return String(data: data, encoding: .utf8)
    }

    func purgeSnapshots(for label: String) {
        let sanitizedLabel = sanitizeForFilename(label)
        guard !sanitizedLabel.isEmpty,
              let baseDir = snapshotsBaseDir else { return }

        snapshots.removeAll { $0.taskLabel == label }

        let dir = baseDir.appendingPathComponent(sanitizedLabel)
        // Validate resolved path is within snapshots dir before deleting
        let resolvedDir = dir.resolvingSymlinksInPath().path
        let resolvedBase = baseDir.resolvingSymlinksInPath().path
        guard resolvedDir.hasPrefix(resolvedBase + "/") else {
            scheduleSave()
            return
        }
        try? fileManager.removeItem(at: dir)

        scheduleSave()
    }

    func purgeAllSnapshots() {
        snapshots.removeAll()

        if let dir = snapshotsBaseDir {
            try? fileManager.removeItem(at: dir)
        }

        scheduleSave()
    }

    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await performSave()
    }

    // MARK: - Private Helpers

    private func readPlistContent(for task: ScheduledTask) -> String? {
        guard let path = task.plistFilePath, fileManager.fileExists(atPath: path) else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func readCronContent(for task: ScheduledTask) async -> String? {
        return await CronService.shared.getCurrentCronEntry(for: task)
    }

    private func sanitizeForFilename(_ label: String) -> String {
        // Strip null bytes first
        let noNulls = label.replacingOccurrences(of: "\0", with: "")
        let sanitized = String(noNulls.unicodeScalars.map { scalar in
            if scalar.isASCII,
               scalar.value >= 0x20,
               "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars.contains(scalar) {
                return Character(scalar)
            }
            return Character("_")
        })
        // Reject path traversal components: "." and ".." would escape the directory
        guard sanitized != ".", sanitized != ".." else { return "" }
        // Strip leading dots to prevent hidden directory creation
        let stripped = String(sanitized.drop(while: { $0 == "." }))
        return stripped.isEmpty ? "_" : stripped
    }

    /// Validate that a snapshot filename contains only safe characters (no path separators).
    private func sanitizeSnapshotFilename(_ name: String) -> String? {
        let noNulls = name.replacingOccurrences(of: "\0", with: "")
        // Reject any path separator or traversal
        guard !noNulls.contains("/"), !noNulls.contains("\\"),
              noNulls != ".", noNulls != "..",
              !noNulls.isEmpty else {
            return nil
        }
        return noNulls
    }

    private func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private func pruneSnapshots() {
        let retentionDays = UserDefaults.standard.integer(forKey: "logRetentionDays")

        // Time-based pruning
        if retentionDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
            let expired = snapshots.filter { $0.timestamp < cutoff }
            for snapshot in expired {
                removeSnapshotFile(snapshot)
            }
            snapshots.removeAll { $0.timestamp < cutoff }
        }

        // Per-task limit
        var countsByLabel: [String: Int] = [:]
        var toRemove: [UUID] = []
        // snapshots are sorted newest-first after insertion
        let sorted = snapshots.sorted { $0.timestamp > $1.timestamp }
        for snapshot in sorted {
            countsByLabel[snapshot.taskLabel, default: 0] += 1
            if (countsByLabel[snapshot.taskLabel] ?? 0) > maxSnapshotsPerTask {
                toRemove.append(snapshot.id)
            }
        }
        for id in toRemove {
            if let snapshot = snapshots.first(where: { $0.id == id }) {
                removeSnapshotFile(snapshot)
            }
        }
        snapshots.removeAll { toRemove.contains($0.id) }

        // Total limit
        if snapshots.count > maxTotalSnapshots {
            let sortedAll = snapshots.sorted { $0.timestamp > $1.timestamp }
            let excess = Array(sortedAll.dropFirst(maxTotalSnapshots))
            for snapshot in excess {
                removeSnapshotFile(snapshot)
            }
            let keepIds = Set(sortedAll.prefix(maxTotalSnapshots).map(\.id))
            snapshots.removeAll { !keepIds.contains($0.id) }
        }
    }

    private func removeSnapshotFile(_ snapshot: TaskSnapshot) {
        let sanitizedLabel = sanitizeForFilename(snapshot.taskLabel)
        guard !sanitizedLabel.isEmpty,
              let safeFileName = sanitizeSnapshotFilename(snapshot.snapshotFileName),
              let baseDir = snapshotsBaseDir else { return }

        let dir = baseDir.appendingPathComponent(sanitizedLabel)
        let filePath = dir.appendingPathComponent(safeFileName)

        // Validate resolved path is within snapshots dir (same check as readSnapshotContent)
        let resolvedPath = filePath.resolvingSymlinksInPath().path
        let resolvedBase = baseDir.resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(resolvedBase + "/") else { return }

        try? fileManager.removeItem(at: filePath)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await performSave()
        }
    }

    /// Max index file size (5 MB). 500 snapshots × ~500 bytes each ≈ 250 KB typical.
    private static let maxIndexReadSize = 5_242_880

    private func loadIndex() {
        guard let url = indexFileURL, fileManager.fileExists(atPath: url.path) else { return }

        do {
            // Bounded read to prevent OOM from tampered index file
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: Self.maxIndexReadSize)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshots = try decoder.decode([TaskSnapshot].self, from: data)
        } catch {
            print("TaskVersionService: Failed to load index: \(error)")
        }
    }

    private func performSave() async {
        guard let appDir = appSupportDir, let url = indexFileURL else { return }

        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshots)
            try data.write(to: url, options: .atomic)

            // Set restrictive permissions
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("TaskVersionService: Failed to save index: \(error)")
        }
    }
}
