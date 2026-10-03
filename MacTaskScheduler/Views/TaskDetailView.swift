//
//  TaskDetailView.swift
//  MacScheduler
//
//  View for displaying task details.
//

import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject var viewModel: TaskListViewModel
    let task: ScheduledTask
    var onEdit: (ScheduledTask) -> Void
    var onRemoveDocker: ((ScheduledTask) -> Void)?

    @State private var showDeleteConfirmation = false
    @State private var showScriptEditor = false
    @State private var showExecutionHistory = false
    @State private var showVersionHistory = false
    @State private var dockerDetailType: DockerDetailType?
    @State private var versionSnapshots: [TaskSnapshot] = []

    private var scriptPath: String? {
        if task.action.type == .shellScript {
            // Check if path points to a script file (not a shell binary)
            let path = task.action.path
            let shellNames = ["bash", "sh", "zsh", "fish", "dash"]
            if !path.isEmpty && !shellNames.contains((path as NSString).lastPathComponent) {
                return path
            }
            // Check arguments for script path
            if let firstArg = task.action.arguments.first,
               !firstArg.hasPrefix("-"),
               FileManager.default.fileExists(atPath: firstArg) {
                return firstArg
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if task.backend == .docker, let containerInfo = task.containerInfo {
                        containerSection(containerInfo)
                    }
                    if task.backend.isVM, let vmInfo = task.vmInfo {
                        vmSection(vmInfo)
                    }
                    if !task.backend.isVM {
                        actionSection
                    }
                    triggerSection
                    if !task.backend.isDiscoverOnly {
                        optionsSection
                    }
                    historySection
                    if !task.isReadOnly && !task.backend.isDiscoverOnly {
                        versionHistorySection
                    }
                }
                .padding()
            }
        }
        .task {
            versionSnapshots = await TaskVersionService.shared.getSnapshots(for: task.launchdLabel)
        }
        .onChange(of: task.launchdLabel) { _, newLabel in
            Task {
                versionSnapshots = await TaskVersionService.shared.getSnapshots(for: newLabel)
            }
        }
        .confirmationDialog("Delete Task", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteTask(task) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(task.name)'? The task configuration will be saved to Trash for recovery.")
        }
        .sheet(isPresented: $showScriptEditor) {
            if let path = scriptPath {
                ScriptEditorView(scriptPath: path, taskName: task.name)
            }
        }
        .sheet(isPresented: $showExecutionHistory) {
            TaskExecutionHistorySheet(task: task)
        }
        .sheet(item: $dockerDetailType) { detailType in
            DockerDetailSheet(detailType: detailType)
        }
        .sheet(isPresented: $showVersionHistory) {
            VersionHistorySheet(task: task)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                headerRow(compact: false)
                headerRow(compact: true)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                actionButtons(iconOnly: false)
                actionButtons(iconOnly: true)
            }
        }
        .padding()
        .background(Color(.textBackgroundColor))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func headerRow(compact: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: task.status.state.systemImage)
                .font(.title)
                .foregroundColor(statusColor(for: task.status.state))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(task.status.state.rawValue)
                        .font(.caption)
                        .foregroundColor(statusColor(for: task.status.state))
                    if task.status.state == .running, let start = task.status.processStartTime {
                        Text("for \(runningDuration(since: start))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if task.status.state == .error {
                        if let exitCode = task.status.lastExitStatus {
                            Text("Exit code \(exitCode)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        if let lastRun = task.status.lastRun {
                            Text("at \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                }
                Text(task.launchdLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if compact {
                headerRightCompact
            } else {
                headerRightFull
            }
        }
    }

    private var headerRightFull: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Label(task.backend.rawValue, systemImage: backendIconName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(backendColor(for: task.backend).opacity(0.2))
                .cornerRadius(6)

            if task.backend == .docker {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.toggleTaskEnabled(task) }
                    } label: {
                        Label(task.status.state == .running ? "Stop" : "Start",
                              systemImage: task.status.state == .running ? "stop.fill" : "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isLoading || task.isStale)
                    .help(task.status.state == .running ? "Stop container" : "Start container")
                }
            } else if task.backend.isVM {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.toggleTaskEnabled(task) }
                    } label: {
                        Label(task.status.state == .running ? "Stop" : "Start",
                              systemImage: task.status.state == .running ? "stop.fill" : "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isLoading)
                    .help(task.status.state == .running ? "Stop VM" : "Start VM")
                }
            } else if task.backend == .launchd {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.loadDaemon(task) }
                    } label: {
                        Label("Load", systemImage: "arrow.up.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(task.isEnabled || viewModel.isLoading)
                    .help("Load this task into launchd")

                    Button {
                        Task { await viewModel.unloadDaemon(task) }
                    } label: {
                        Label("Unload", systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!task.isEnabled || viewModel.isLoading)
                    .help("Unload this task from launchd")
                }
            }

            Text("Created \(task.createdAt, style: .date)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var headerRightCompact: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Image(systemName: backendIconName)
                .font(.caption)
                .padding(6)
                .background(backendColor(for: task.backend).opacity(0.2))
                .cornerRadius(6)
                .help(task.backend.rawValue)

            if task.backend == .docker || task.backend.isVM {
                Button {
                    Task { await viewModel.toggleTaskEnabled(task) }
                } label: {
                    Image(systemName: task.status.state == .running ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading || task.isStale)
                .help(task.status.state == .running ? "Stop" : "Start")
            } else if task.backend == .launchd {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.loadDaemon(task) }
                    } label: {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(task.isEnabled || viewModel.isLoading)
                    .help("Load this task into launchd")

                    Button {
                        Task { await viewModel.unloadDaemon(task) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!task.isEnabled || viewModel.isLoading)
                    .help("Unload this task from launchd")
                }
            }
        }
    }

    private var actionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Action", systemImage: task.action.type.systemImage)
                        .font(.headline)
                    Spacer()
                    if scriptPath != nil {
                        Button {
                            showScriptEditor = true
                        } label: {
                            Label("Edit Script", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .help("Open the script file in the editor")
                    }
                }

                Divider()

                InfoRow(label: "Type", value: task.action.type.rawValue)

                if !task.action.path.isEmpty {
                    InfoRow(label: "Path", value: task.action.path, monospaced: true)
                }

                if !task.action.arguments.isEmpty {
                    InfoRow(label: "Arguments", value: task.action.arguments.joined(separator: " "), monospaced: true)
                }

                if let workDir = task.action.workingDirectory, !workDir.isEmpty {
                    InfoRow(label: "Working Directory", value: workDir, monospaced: true)
                }

                // Show script file path with actions
                if let path = scriptPath {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Script File")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                        .padding(8)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                    }
                }

                if let script = task.action.scriptContent, !script.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inline Script")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ScrollView {
                            Text(script)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                        .padding(8)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private var triggerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Trigger", systemImage: task.trigger.type.systemImage)
                    .font(.headline)

                Divider()

                InfoRow(label: "Type", value: task.trigger.type.rawValue)
                InfoRow(label: "Schedule", value: task.trigger.displayString)

                if let nextRun = task.status.nextScheduledRun {
                    InfoRow(label: "Next Run", value: nextRun.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Options", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Divider()

                HStack {
                    Toggle("Run at Load", isOn: .constant(task.runAtLoad))
                        .disabled(true)
                    Spacer()
                    Toggle("Keep Alive", isOn: .constant(task.keepAlive))
                        .disabled(true)
                }

                if let outPath = task.standardOutPath, !outPath.isEmpty {
                    InfoRow(label: "Standard Output", value: outPath, monospaced: true)
                }

                if let errPath = task.standardErrorPath, !errPath.isEmpty {
                    InfoRow(label: "Standard Error", value: errPath, monospaced: true)
                }

                InfoRow(label: "Location", value: task.location.rawValue)

                if let userName = task.userName, !userName.isEmpty {
                    InfoRow(label: "Run As User", value: userName)
                }

                if let dir = task.plistFilePath {
                    InfoRow(label: "Plist Path", value: dir, monospaced: true)
                }

                if task.isReadOnly {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.secondary)
                        Text("System task (read-only)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var historySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Execution History", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Button {
                        showExecutionHistory = true
                    } label: {
                        Label("View All", systemImage: "list.bullet")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("View all past executions")
                }

                Divider()

                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("\(task.status.runCount)")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Total Runs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading) {
                        Text("\(task.status.failureCount)")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(task.status.failureCount > 0 ? .red : .primary)
                        Text("Failures")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if task.status.state == .running, let start = task.status.processStartTime {
                        VStack(alignment: .leading) {
                            Text(runningDuration(since: start))
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            Text("Uptime")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if let lastRun = task.status.lastRun {
                        VStack(alignment: .leading) {
                            Text(lastRun.formatted(date: .abbreviated, time: .shortened))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text("Last Run")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if task.status.state == .error, let exitCode = task.status.lastExitStatus {
                        VStack(alignment: .leading) {
                            Text("\(exitCode)")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            Text("Exit Code")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }

                if let lastResult = task.status.lastResult {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last Execution")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            Label(lastResult.success ? "Success" : "Failed",
                                  systemImage: lastResult.success ? "checkmark.circle" : "xmark.circle")
                                .foregroundColor(lastResult.success ? .green : .red)

                            Spacer()

                            Text("Exit code: \(lastResult.exitCode)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Duration: \(String(format: "%.2fs", lastResult.duration))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !lastResult.standardOutput.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ScrollView {
                                    Text(lastResult.standardOutput)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 100)
                                .padding(8)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(6)
                            }
                        }

                        if !lastResult.standardError.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Errors")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                ScrollView {
                                    Text(lastResult.standardError)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 100)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                    }
                }

                logFileOutputSection
            }
        }
    }

    private var versionHistorySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Version History", systemImage: "clock.arrow.2.circlepath")
                        .font(.headline)
                    Spacer()
                    if !versionSnapshots.isEmpty {
                        Button {
                            showVersionHistory = true
                        } label: {
                            Label("View All", systemImage: "list.bullet")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("View all version history")
                    }
                }

                Divider()

                if versionSnapshots.isEmpty {
                    Text("No version history recorded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(versionSnapshots.count) version\(versionSnapshots.count == 1 ? "" : "s") saved")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(versionSnapshots.prefix(3)) { snapshot in
                        HStack(spacing: 8) {
                            Image(systemName: snapshot.reason == .beforeEdit ? "pencil.circle" : "trash.circle")
                                .foregroundColor(snapshot.reason == .beforeEdit ? .blue : .red)
                                .font(.caption)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                Text(snapshot.reason == .beforeEdit ? "Before Edit" : "Before Delete")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// Show stdout/stderr log file contents from native launchd execution (not just "Run Now").
    @ViewBuilder
    private var logFileOutputSection: some View {
        let stdoutContent = readLogFileTail(task.standardOutPath)
        let stderrContent = readLogFileTail(task.standardErrorPath)

        if stdoutContent != nil || stderrContent != nil {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Log Output")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("From log files on disk")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let stdout = stdoutContent {
                    logFileBox(
                        label: "Standard Output",
                        path: task.standardOutPath ?? "",
                        content: stdout,
                        isError: false
                    )
                }

                if let stderr = stderrContent {
                    logFileBox(
                        label: "Standard Error",
                        path: task.standardErrorPath ?? "",
                        content: stderr,
                        isError: true
                    )
                }
            }
        }
    }

    private func logFileBox(label: String, path: String, content: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(isError ? .red : .secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reveal log file in Finder")
            }
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(isError ? .red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(isError ? Color.red.opacity(0.1) : Color(.textBackgroundColor))
            .cornerRadius(6)
        }
    }

    /// Read the last portion of a log file, returning nil if the file doesn't exist or is empty.
    private func readLogFileTail(_ path: String?, maxBytes: Int = 8192) -> String? {
        guard let path = path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > 0 else {
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let readSize = min(UInt64(maxBytes), fileSize)
        if fileSize > readSize {
            handle.seek(toFileOffset: fileSize - readSize)
        }
        let data = handle.readData(ofLength: Int(readSize))
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else { return nil }

        // If we truncated, indicate that
        if fileSize > readSize {
            return "[... showing last \(readSize) bytes ...]\n" + content
        }
        return content
    }

    @ViewBuilder
    private func actionButtons(iconOnly: Bool) -> some View {
        if iconOnly {
            actionButtonsContent
                .labelStyle(.iconOnly)
        } else {
            actionButtonsContent
                .labelStyle(.titleAndIcon)
        }
    }

    private var actionButtonsContent: some View {
        HStack(spacing: 8) {
            if task.backend == .docker {
                Button {
                    Task { await viewModel.runTaskNow(task) }
                } label: {
                    Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading || task.isStale)
                .help("Restart this container")

                Button {
                    Task { await viewModel.toggleTaskEnabled(task) }
                } label: {
                    Label(task.status.state == .running ? "Stop" : "Start",
                          systemImage: task.status.state == .running ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading || task.isStale)
                .help(task.status.state == .running ? "Stop container" : "Start container")

                Button {
                    onEdit(task)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(task.isStale)
                .help("Edit container configuration")
            } else if task.backend.isVM {
                Button {
                    Task { await viewModel.toggleTaskEnabled(task) }
                } label: {
                    Label(task.status.state == .running ? "Stop" : "Start",
                          systemImage: task.status.state == .running ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading)
                .help(task.status.state == .running ? "Stop VM" : "Start VM")
            } else {
                Button {
                    Task { await viewModel.runTaskNow(task) }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading)
                .help("Execute this task immediately")

                Button {
                    Task { await viewModel.toggleTaskEnabled(task) }
                } label: {
                    Label(task.isEnabled ? "Disable" : "Enable",
                          systemImage: task.isEnabled ? "pause.fill" : "checkmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isLoading)
                .help(task.isEnabled ? "Unload task from launchd" : "Load task into launchd")

                Button {
                    onEdit(task)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(task.isReadOnly)
                .help("Edit task configuration")
            }

            Button {
                Task { await viewModel.refreshTaskStatus(task) }
            } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading)
            .help("Refresh task status")

            Spacer()

            if task.backend == .docker {
                Button(role: .destructive) {
                    onRemoveDocker?(task)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(task.isStale)
                .help("Remove this container")
            } else if !task.backend.isVM {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(task.isReadOnly)
                .help("Delete this task and its plist file")
            }
        }
    }

    private func containerSection(_ info: ContainerInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Container", systemImage: "shippingbox")
                    .font(.headline)

                Divider()

                InfoRow(label: "Container ID", value: info.containerId, monospaced: true)

                // Tappable: Image → inspect
                Button {
                    dockerDetailType = .imageInspect(info.imageName)
                } label: {
                    HStack {
                        InfoRow(label: "Image", value: info.imageName, monospaced: true)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(task.isStale)

                InfoRow(label: "Runtime", value: info.runtime.rawValue)

                // Tappable: Launch Origin → detail
                Button {
                    dockerDetailType = .launchOriginDetail(info)
                } label: {
                    HStack {
                        InfoRow(label: "Launch Origin", value: info.launchOrigin.rawValue)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(task.isStale)

                InfoRow(label: "Restart Policy", value: info.restartPolicy, monospaced: true)
                InfoRow(label: "Status", value: info.containerStatus)

                if let project = info.composeProject {
                    // Tappable: Compose Project → config
                    Button {
                        dockerDetailType = .composeConfig(project)
                    } label: {
                        HStack {
                            InfoRow(label: "Compose Project", value: project)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(task.isStale)
                }
                if let service = info.composeService {
                    InfoRow(label: "Compose Service", value: service)
                }
                if let networkMode = info.networkMode, !networkMode.isEmpty {
                    InfoRow(label: "Network Mode", value: networkMode)
                }

                if !info.ports.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ports")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(info.ports, id: \.self) { port in
                            Text(port)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                if !info.volumes.isEmpty {
                    // Tappable: Volumes → inspect
                    Button {
                        // Extract volume names from "source:dest" format
                        let volumeNames = info.volumes.compactMap { vol -> String? in
                            let parts = vol.components(separatedBy: ":")
                            guard let source = parts.first, !source.isEmpty else { return nil }
                            // Only named volumes (not host paths) can be inspected
                            if source.hasPrefix("/") { return nil }
                            return source
                        }
                        if !volumeNames.isEmpty {
                            dockerDetailType = .volumeInspect(volumeNames)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Volumes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            ForEach(info.volumes, id: \.self) { volume in
                                Text(volume)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(task.isStale)
                }

                if !info.command.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(info.command.joined(separator: " "))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let entrypoint = info.entrypoint, !entrypoint.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Entrypoint")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(entrypoint.joined(separator: " "))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if !info.environmentVariables.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment Variables")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(info.environmentVariables.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 4) {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.medium)
                                Text("=")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if let createdAt = info.createdAt {
                    InfoRow(label: "Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    private func vmSection(_ info: VMInfo) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Virtual Machine", systemImage: "desktopcomputer")
                    .font(.headline)

                Divider()

                InfoRow(label: "VM ID", value: info.vmId, monospaced: true)
                InfoRow(label: "State", value: info.vmState)

                if let osType = info.osType {
                    InfoRow(label: "OS Type", value: osType)
                }
                if let cpuCount = info.cpuCount {
                    InfoRow(label: "CPUs", value: "\(cpuCount)")
                }
                if let memoryMB = info.memoryMB {
                    InfoRow(label: "Memory", value: "\(memoryMB) MB")
                }
            }
        }
    }

    private var backendIconName: String {
        switch task.backend {
        case .launchd: return "gear"
        case .cron: return "terminal"
        case .docker: return "shippingbox"
        case .parallels, .virtualBox, .utm, .vmwareFusion: return "desktopcomputer"
        }
    }

    private func backendColor(for backend: SchedulerBackend) -> Color {
        switch backend {
        case .launchd: return .blue
        case .cron: return .orange
        case .docker: return .teal
        case .parallels: return .purple
        case .virtualBox: return .indigo
        case .utm: return .mint
        case .vmwareFusion: return .brown
        }
    }

    private func runningDuration(since start: Date) -> String {
        let interval = Date().timeIntervalSince(start)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    private func statusColor(for state: TaskState) -> Color {
        switch state {
        case .enabled: return .green
        case .disabled: return .secondary
        case .running: return .blue
        case .error: return .red
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            if monospaced {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .textSelection(.enabled)
            }

            Spacer()
        }
    }
}

struct TaskExecutionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: ScheduledTask
    @State private var history: [TaskExecutionResult] = []
    @State private var selectedResult: TaskExecutionResult?
    private let historyService = TaskHistoryService.shared

    var body: some View {
        NavigationStack {
            Group {
                if history.isEmpty {
                    ContentUnavailableView {
                        Label("No Executions", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("No execution history recorded for this task.\nCheck the Log Output section in the task detail for output from scheduled runs.")
                    }
                } else {
                    List(history) { result in
                        TaskExecutionRow(result: result)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedResult = result
                            }
                    }
                }
            }
            .navigationTitle("Executions — \(task.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 550, minHeight: 400)
        .task {
            history = await historyService.getHistory(for: task.id)
        }
        .sheet(item: $selectedResult) { result in
            ExecutionDetailSheet(result: result, taskName: task.name)
        }
    }
}

struct TaskExecutionRow: View {
    let result: TaskExecutionResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.success ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.startTime.formatted(date: .abbreviated, time: .shortened))
                    .fontWeight(.medium)
                Text("\(result.startTime, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(String(format: "%.2fs", result.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)

            Text("Exit \(result.exitCode)")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(result.success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                .cornerRadius(4)
                .fixedSize()

            if !result.standardOutput.isEmpty || !result.standardError.isEmpty {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Has output — click to view")
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TaskDetailView(task: .example, onEdit: { _ in }, onRemoveDocker: { _ in })
        .environmentObject(TaskListViewModel())
}
