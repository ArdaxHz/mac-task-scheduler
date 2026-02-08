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
        .navigationTitle(task.name)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await viewModel.refreshTaskStatus(task) }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Refresh task status")
                .disabled(viewModel.isLoading)

                Button {
                    Task { await viewModel.runTaskNow(task) }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .help("Execute this task immediately")
                .disabled(viewModel.isLoading)

                Button {
                    Task { await viewModel.toggleTaskEnabled(task) }
                } label: {
                    if task.isEnabled {
                        Label("Disable", systemImage: "pause.fill")
                    } else {
                        Label("Enable", systemImage: "checkmark")
                    }
                }
                .help(task.isEnabled ? "Unload task from launchd" : "Load task into launchd")
                .disabled(viewModel.isLoading)

                Button {
                    onEdit(task)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit task configuration")
                .disabled(task.isReadOnly)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this task and its plist file")
                .disabled(task.isReadOnly)
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
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: task.status.state.systemImage)
                    .font(.title)
                    .foregroundColor(statusColor(for: task.status.state))

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.status.state.rawValue)
                        .font(.headline)
                    Text(task.launchdLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

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
        }
        .padding()
        .background(Color(.textBackgroundColor))
        .cornerRadius(12)
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

                if let dir = task.plistFilePath {
                    InfoRow(label: "Plist Location", value: dir, monospaced: true)
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
                Label("Execution History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

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

                    if let lastRun = task.status.lastRun {
                        VStack(alignment: .leading) {
                            Text(lastRun.formatted(date: .abbreviated, time: .shortened))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text("Last Run")
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
            }
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

#Preview {
    TaskDetailView(task: .example, onEdit: { _ in })
        .environmentObject(TaskListViewModel())
}
