//
//  TaskEditorView.swift
//  MacScheduler
//
//  Form for creating and editing tasks.
//

import SwiftUI

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editorViewModel = TaskEditorViewModel()

    let task: ScheduledTask?
    let onSave: (ScheduledTask) -> Void

    @State private var showFilePicker = false
    @State private var filePickerField: FilePickerField = .executable

    enum FilePickerField {
        case executable
        case workingDirectory
        case standardOut
        case standardError
    }

    init(task: ScheduledTask? = nil, onSave: @escaping (ScheduledTask) -> Void) {
        self.task = task
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                actionSection
                triggerSection
                optionsSection
            }
            .formStyle(.grouped)
            .navigationTitle(editorViewModel.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .help("Discard changes and close")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(editorViewModel.name.isEmpty)
                    .help("Save task and reload launchd daemon")
                }
            }
            .alert("Validation Errors", isPresented: $editorViewModel.showValidationErrors) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editorViewModel.validationErrors.joined(separator: "\n"))
            }
            .onAppear {
                if let task = task {
                    editorViewModel.loadTask(task)
                } else {
                    editorViewModel.reset()
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFilePicker(result)
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }

    private var basicInfoSection: some View {
        Section("Basic Information") {
            TextField("Task Name", text: $editorViewModel.name)
                .onChange(of: editorViewModel.name) { _, _ in
                    editorViewModel.updateLabelFromName()
                }

            TextField("Description", text: $editorViewModel.taskDescription, axis: .vertical)
                .lineLimit(2...4)

            TextField("Label (e.g. com.user.my-task)", text: $editorViewModel.taskLabel)
                .font(.system(.body, design: .monospaced))
                .help("The native launchd label / plist filename. This is how macOS identifies the task.")
                .disabled(editorViewModel.isEditing && (task?.isReadOnly ?? false))

            Picker("Backend", selection: $editorViewModel.backend) {
                ForEach(SchedulerBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .help("launchd is the native macOS scheduler; cron is the traditional Unix scheduler")
        }
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("Action Type", selection: $editorViewModel.actionType) {
                ForEach(TaskActionType.allCases, id: \.self) { type in
                    Label(type.rawValue, systemImage: type.systemImage).tag(type)
                }
            }
            .help("Executable: run a binary directly. Shell Script: run a bash/zsh script. AppleScript: run an AppleScript command")

            switch editorViewModel.actionType {
            case .executable:
                executableFields
            case .shellScript:
                shellScriptFields
            case .appleScript:
                appleScriptFields
            }

            HStack {
                TextField("Working Directory (optional)", text: $editorViewModel.workingDirectory)
                Button {
                    filePickerField = .workingDirectory
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for working directory")
            }

            tccWarning(for: $editorViewModel.workingDirectory, isDirectory: true)
        }
    }

    private var executableFields: some View {
        Group {
            HStack {
                TextField("Executable Path", text: $editorViewModel.executablePath)
                Button {
                    filePickerField = .executable
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for executable")
            }

            tccWarning(for: $editorViewModel.executablePath)

            TextField("Arguments (space-separated)", text: $editorViewModel.arguments)
        }
    }

    private var shellScriptFields: some View {
        Group {
            HStack {
                TextField("Script Path (optional)", text: $editorViewModel.executablePath)
                Button {
                    filePickerField = .executable
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for script file")
            }

            tccWarning(for: $editorViewModel.executablePath)

            VStack(alignment: .leading) {
                Text("Script Content")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $editorViewModel.scriptContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .border(Color.secondary.opacity(0.3))
            }
        }
    }

    private var appleScriptFields: some View {
        Group {
            HStack {
                TextField("Script Path (optional)", text: $editorViewModel.executablePath)
                Button {
                    filePickerField = .executable
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for AppleScript file")
            }

            tccWarning(for: $editorViewModel.executablePath)

            VStack(alignment: .leading) {
                Text("AppleScript Content")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $editorViewModel.scriptContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .border(Color.secondary.opacity(0.3))
            }
        }
    }

    private var triggerSection: some View {
        Section("Trigger") {
            Picker("Trigger Type", selection: $editorViewModel.triggerType) {
                ForEach(TriggerType.allCases, id: \.self) { type in
                    HStack {
                        Label(type.rawValue, systemImage: type.systemImage)
                        if editorViewModel.backend == .cron && !type.supportsCron {
                            Text("(Not supported by cron)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(type)
                }
            }
            .help(editorViewModel.triggerType.description)

            switch editorViewModel.triggerType {
            case .calendar:
                TriggerEditorView(
                    minute: $editorViewModel.scheduleMinute,
                    hour: $editorViewModel.scheduleHour,
                    day: $editorViewModel.scheduleDay,
                    weekday: $editorViewModel.scheduleWeekday,
                    month: $editorViewModel.scheduleMonth
                )
            case .interval:
                intervalFields
            case .atLogin, .atStartup, .onDemand:
                Text(editorViewModel.triggerType.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var intervalFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Every")
                    .foregroundColor(.secondary)

                TextField("", value: $editorViewModel.intervalValue, format: .number)
                    .textFieldStyle(.roundedBorder)

                Picker("Unit", selection: $editorViewModel.intervalUnit) {
                    ForEach(TaskEditorViewModel.IntervalUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .frame(maxWidth: .infinity)

            let totalSeconds = editorViewModel.intervalValue * editorViewModel.intervalUnit.multiplier
            Text("Runs every \(formattedInterval(totalSeconds))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func formattedInterval(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds) second\(totalSeconds == 1 ? "" : "s")"
        } else if totalSeconds < 3600 {
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            if secs == 0 {
                return "\(mins) minute\(mins == 1 ? "" : "s")"
            }
            return "\(mins) min \(secs) sec"
        } else if totalSeconds < 86400 {
            let hours = totalSeconds / 3600
            let mins = (totalSeconds % 3600) / 60
            if mins == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "\(hours) hr \(mins) min"
        } else {
            let days = totalSeconds / 86400
            let hours = (totalSeconds % 86400) / 3600
            if hours == 0 {
                return "\(days) day\(days == 1 ? "" : "s")"
            }
            return "\(days) day\(days == 1 ? "" : "s") \(hours) hr"
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Run at Load", isOn: $editorViewModel.runAtLoad)
                .help("Run the task when it is loaded (enabled)")

            Toggle("Keep Alive", isOn: $editorViewModel.keepAlive)
                .help("Restart the task if it exits")
                .disabled(editorViewModel.backend == .cron)

            HStack {
                TextField("Standard Output Path (optional)", text: $editorViewModel.standardOutPath)
                    .help("File path where the task's standard output will be written")
                Button {
                    filePickerField = .standardOut
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for stdout log file location")
            }

            tccWarning(for: $editorViewModel.standardOutPath)

            HStack {
                TextField("Standard Error Path (optional)", text: $editorViewModel.standardErrorPath)
                    .help("File path where the task's error output will be written")
                Button {
                    filePickerField = .standardError
                    showFilePicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .help("Browse for stderr log file location")
            }

            tccWarning(for: $editorViewModel.standardErrorPath)
        }
    }

    @ViewBuilder
    private func tccWarning(for path: Binding<String>, isDirectory: Bool = false) -> some View {
        if !path.wrappedValue.isEmpty && TaskEditorViewModel.isTCCProtected(path.wrappedValue) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("This path is in a TCC-protected folder (Documents, Desktop, or Downloads). launchd cannot access files there.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                HStack(spacing: 8) {
                    if !isDirectory && FileManager.default.fileExists(atPath: path.wrappedValue) {
                        Button {
                            if let newPath = editorViewModel.copyFileToScriptsDirectory(from: path.wrappedValue) {
                                path.wrappedValue = newPath
                            }
                        } label: {
                            Label("Copy to ~/Library/Scripts/", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .help("Copy this file to the scripts directory where launchd can access it")
                    }

                    Button {
                        let revealPath = path.wrappedValue
                        if FileManager.default.fileExists(atPath: revealPath) {
                            NSWorkspace.shared.selectFile(revealPath, inFileViewerRootedAtPath: "")
                        } else {
                            let parent = (revealPath as NSString).deletingLastPathComponent
                            NSWorkspace.shared.open(URL(fileURLWithPath: parent))
                        }
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(.caption)
                    }
                    .help("Show this file in Finder")
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
    }

    private func save() {
        guard editorViewModel.validate() else { return }

        let task = editorViewModel.buildTask()
        onSave(task)
        dismiss()
    }

    private func handleFilePicker(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let path = url.path
        switch filePickerField {
        case .executable:
            editorViewModel.executablePath = path
        case .workingDirectory:
            editorViewModel.workingDirectory = path
        case .standardOut:
            editorViewModel.standardOutPath = path
        case .standardError:
            editorViewModel.standardErrorPath = path
        }
    }
}

#Preview {
    TaskEditorView(onSave: { _ in })
}
