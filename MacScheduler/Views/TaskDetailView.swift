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

    @State private var showDeleteConfirmation = false
    @State private var showScriptEditor = false
    @State private var showExecutionHistory = false

    private var scriptPath: String? {
        if task.action.type == .shellScript {
            // Check if path points to a script file (not a shell binary)
            let path = task.action.path
            if !path.isEmpty && !path.hasSuffix("bash") && !path.hasSuffix("sh") && !path.hasSuffix("zsh") {
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
                    actionSection
                    triggerSection
                    optionsSection
                    historySection
                }
                .padding()
            }
        }
        .confirmationDialog("Delete Task", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteTask(task) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(task.name)'? This action cannot be undone.")
        }
        .sheet(isPresented: $showScriptEditor) {
            if let path = scriptPath {
                ScriptEditorView(scriptPath: path, taskName: task.name)
            }
        }
        .sheet(isPresented: $showExecutionHistory) {
            TaskExecutionHistorySheet(task: task)
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
            Label(task.backend.rawValue, systemImage: "gear")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(task.backend == .launchd ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                .cornerRadius(6)

            if task.backend == .launchd {
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
            Image(systemName: "gear")
                .font(.caption)
                .padding(6)
                .background(task.backend == .launchd ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                .cornerRadius(6)
                .help(task.backend.rawValue)

            if task.backend == .launchd {
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
    TaskDetailView(task: .example, onEdit: { _ in })
        .environmentObject(TaskListViewModel())
}
