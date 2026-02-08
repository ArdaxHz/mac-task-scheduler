//
//  MainView.swift
//  MacScheduler
//
//  Main window with sidebar navigation.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var viewModel: TaskListViewModel
    @State private var activeSheet: EditorSheet?
    @State private var selectedNavItem: NavigationItem = .allTasks

    enum NavigationItem: Hashable {
        case allTasks
        case history
    }

    enum EditorSheet: Identifiable {
        case newTask
        case editTask(ScheduledTask)

        var id: String {
            switch self {
            case .newTask: return "new-task"
            case .editTask(let task): return task.id.uuidString
            }
        }

        var task: ScheduledTask? {
            switch self {
            case .newTask: return nil
            case .editTask(let task): return task
            }
        }
    }

    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @State private var showInspector = true
    @State private var showUpdateAlert = false
    @State private var availableUpdate: UpdateService.Release?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            contentView
        }
        .toolbar(removing: .sidebarToggle)
        .inspector(isPresented: $showInspector) {
            detailView
                .inspectorColumnWidth(min: 200, ideal: 350, max: 500)
        }
        .onChange(of: viewModel.selectedTask) { _, newTask in
            if newTask != nil && !showInspector {
                showInspector = true
            }
        }
        .sheet(item: $activeSheet) { sheet in
            TaskEditorView(task: sheet.task) { task in
                if sheet.task != nil {
                    Task { await viewModel.updateTask(task) }
                } else {
                    Task { await viewModel.addTask(task) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewTask)) { _ in
            activeSheet = .newTask
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
        .alert("Update Available", isPresented: $showUpdateAlert) {
            if let update = availableUpdate {
                Button("Download") {
                    if let url = URL(string: update.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Later", role: .cancel) {}
            }
        } message: {
            if let update = availableUpdate {
                Text("Version \(update.version) is available. You are currently on v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?").")
            }
        }
        .task {
            guard autoCheckUpdates else { return }
            if let release = await UpdateService.shared.checkForUpdate() {
                availableUpdate = release
                showUpdateAlert = true
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedNavItem) {
            Section("Tasks") {
                Label("All Tasks", systemImage: "list.bullet")
                    .badge(viewModel.tasks.count)
                    .tag(NavigationItem.allTasks)
            }

            Section("Activity") {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(NavigationItem.history)
            }

            Section("Status") {
                ForEach(TaskState.allCases, id: \.self) { state in
                    Button {
                        if viewModel.filterStates.contains(state) {
                            viewModel.filterStates.remove(state)
                        } else {
                            viewModel.filterStates.insert(state)
                        }
                        selectedNavItem = .allTasks
                    } label: {
                        HStack {
                            Image(systemName: viewModel.filterStates.contains(state) ? "checkmark.square.fill" : "square")
                                .foregroundColor(viewModel.filterStates.contains(state) ? statusColor(for: state) : .secondary)
                            Label(state.rawValue, systemImage: state.systemImage)
                                .foregroundColor(statusColor(for: state))
                            Spacer()
                            Text("\(viewModel.tasks.filter { $0.status.state == state }.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 140, ideal: 190, max: 250)
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedNavItem {
        case .allTasks:
            TaskListView(
                onAdd: {
                    activeSheet = .newTask
                },
                onEdit: { task in
                    activeSheet = .editTask(task)
                },
                onSelect: { task in
                    viewModel.selectedTask = task
                }
            )
        case .history:
            HistoryView()
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

    @ViewBuilder
    private var detailView: some View {
        if let task = viewModel.selectedTask {
            TaskDetailView(task: task) { task in
                activeSheet = .editTask(task)
            }
        } else {
            ContentUnavailableView {
                Label("No Task Selected", systemImage: "calendar.badge.clock")
            } description: {
                Text("Select a task from the list to view its details")
            }
        }
    }
}

#Preview {
    MainView()
        .environmentObject(TaskListViewModel())
}
