//
//  TaskListView.swift
//  MacScheduler
//
//  List view showing all scheduled tasks.
//

import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var viewModel: TaskListViewModel
    var onAdd: () -> Void
    var onEdit: (ScheduledTask) -> Void
    var onSelect: (ScheduledTask) -> Void

    @State private var sortOrder = [KeyPathComparator(\ScheduledTask.name, order: .forward)]
    @State private var selectedTaskId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            Divider()

            if viewModel.filteredTasks.isEmpty {
                emptyState
            } else {
                taskTable
            }
        }
        .navigationTitle("Scheduled Tasks")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onAdd()
                } label: {
                    Label("Add Task", systemImage: "plus")
                }
                .help("Create a new scheduled task")

                Button {
                    Task {
                        await viewModel.refreshAll()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Refresh all tasks from live LaunchAgents and cron")
                .disabled(viewModel.isLoading)

                Button {
                    Task { await viewModel.loadAllDaemons() }
                } label: {
                    Label("Load All", systemImage: "arrow.up.circle")
                }
                .help("Load all launchd tasks into the daemon")
                .disabled(viewModel.isLoading)

                Button {
                    Task { await viewModel.unloadAllDaemons() }
                } label: {
                    Label("Unload All", systemImage: "arrow.down.circle")
                }
                .help("Unload all launchd tasks from the daemon")
                .disabled(viewModel.isLoading)
            }
        }
    }

    private var hasActiveFilters: Bool {
        !viewModel.filterStates.isEmpty ||
        viewModel.filterBackend != nil ||
        viewModel.filterTriggerType != nil ||
        viewModel.filterLastRun != .all ||
        viewModel.filterOwnership != .all
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search tasks...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)

                HStack(spacing: 4) {
                    ForEach(TaskState.allCases, id: \.self) { state in
                        StatusFilterChip(
                            state: state,
                            isSelected: viewModel.filterStates.contains(state),
                            color: statusColor(for: state)
                        ) {
                            if viewModel.filterStates.contains(state) {
                                viewModel.filterStates.remove(state)
                            } else {
                                viewModel.filterStates.insert(state)
                            }
                        }
                    }
                }
                .fixedSize()
            }

            HStack(spacing: 8) {
                // Trigger type filter
                Menu {
                    Button {
                        viewModel.filterTriggerType = nil
                    } label: {
                        HStack {
                            Text("All Triggers")
                            if viewModel.filterTriggerType == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(TriggerType.allCases, id: \.self) { type in
                        Button {
                            viewModel.filterTriggerType = type
                        } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.systemImage)
                                if viewModel.filterTriggerType == type {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.caption2)
                        Text(viewModel.filterTriggerType?.rawValue ?? "Trigger")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.filterTriggerType != nil ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundColor(viewModel.filterTriggerType != nil ? .accentColor : .secondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(viewModel.filterTriggerType != nil ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by trigger type")

                // Backend filter
                Menu {
                    Button {
                        viewModel.filterBackend = nil
                    } label: {
                        HStack {
                            Text("All Backends")
                            if viewModel.filterBackend == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(SchedulerBackend.allCases, id: \.self) { backend in
                        Button {
                            viewModel.filterBackend = backend
                        } label: {
                            HStack {
                                Text(backend.displayName)
                                if viewModel.filterBackend == backend {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.caption2)
                        Text(viewModel.filterBackend?.rawValue ?? "Backend")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.filterBackend != nil ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundColor(viewModel.filterBackend != nil ? .accentColor : .secondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(viewModel.filterBackend != nil ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by scheduler backend")

                // Last Run filter
                Menu {
                    ForEach(TaskListViewModel.LastRunFilter.allCases, id: \.self) { filter in
                        Button {
                            viewModel.filterLastRun = filter
                        } label: {
                            HStack {
                                Text(filter.rawValue)
                                if viewModel.filterLastRun == filter {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(viewModel.filterLastRun == .all ? "Last Run" : viewModel.filterLastRun.rawValue)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.filterLastRun != .all ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundColor(viewModel.filterLastRun != .all ? .accentColor : .secondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(viewModel.filterLastRun != .all ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by last run status")

                // User/System filter
                Menu {
                    ForEach(TaskListViewModel.OwnershipFilter.allCases, id: \.self) { filter in
                        Button {
                            viewModel.filterOwnership = filter
                        } label: {
                            HStack {
                                Text(filter.rawValue)
                                if viewModel.filterOwnership == filter {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                        Text(viewModel.filterOwnership == .all ? "Scope" : viewModel.filterOwnership.rawValue)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.filterOwnership != .all ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundColor(viewModel.filterOwnership != .all ? .accentColor : .secondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(viewModel.filterOwnership != .all ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by user or system tasks")

                Spacer()

                if hasActiveFilters {
                    Button {
                        viewModel.filterStates.removeAll()
                        viewModel.filterBackend = nil
                        viewModel.filterTriggerType = nil
                        viewModel.filterLastRun = .all
                        viewModel.filterOwnership = .all
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Clear Filters")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all filters")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var taskTable: some View {
        Table(viewModel.filteredTasks, selection: $selectedTaskId, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusName) { task in
                Image(systemName: task.status.state.systemImage)
                    .foregroundColor(statusColor(for: task.status.state))
            }
            .width(20)

            TableColumn("Name", value: \.name) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .fontWeight(.medium)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 100, ideal: 200)

            TableColumn("Trigger", value: \.triggerTypeName) { task in
                HStack(spacing: 6) {
                    Image(systemName: task.trigger.type.systemImage)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text(task.trigger.displayString)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(task.trigger.displayString)
            }
            .width(min: 80, ideal: 180, max: 280)

            TableColumn("Backend", value: \.backendName) { task in
                Text(task.backend.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(task.backend == .launchd ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Last Run", value: \.lastRunDate) { task in
                if task.status.state == .running, let start = task.status.processStartTime {
                    Text("Up \(start, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .help("Running since \(start.formatted(date: .abbreviated, time: .shortened))")
                } else if task.status.state == .error, let exitCode = task.status.lastExitStatus {
                    Text("Exit \(exitCode)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .help(task.status.lastRun != nil ? "Failed at \(task.status.lastRun!.formatted(date: .abbreviated, time: .shortened))" : "Failed with exit code \(exitCode)")
                } else if let lastRun = task.status.lastRun {
                    Text(lastRun.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("\(lastRun, style: .relative) ago")
                } else {
                    Text("Never")
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 80, ideal: 150)
        }
        .contextMenu(forSelectionType: ScheduledTask.ID.self) { ids in
            if let id = ids.first, let task = viewModel.tasks.first(where: { $0.id == id }) {
                contextMenuItems(for: task)
            }
        } primaryAction: { ids in
            if let id = ids.first, let task = viewModel.tasks.first(where: { $0.id == id }) {
                onSelect(task)
            }
        }
        .onChange(of: sortOrder) { _, newOrder in
            viewModel.tasks.sort(using: newOrder)
        }
        .onChange(of: selectedTaskId) { _, newId in
            if let id = newId {
                viewModel.selectedTask = viewModel.tasks.first { $0.id == id }
            } else {
                viewModel.selectedTask = nil
            }
        }
        .onChange(of: viewModel.selectedTask) { _, newTask in
            // Sync back: when ViewModel updates selectedTask (e.g. after refresh), update table selection
            if selectedTaskId != newTask?.id {
                selectedTaskId = newTask?.id
            }
        }
        .onChange(of: viewModel.tasks) { _, _ in
            // When task list refreshes, sync selection to keep it in sync
            if let currentId = selectedTaskId,
               !viewModel.tasks.contains(where: { $0.id == currentId }) {
                selectedTaskId = nil
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for task: ScheduledTask) -> some View {
        Button {
            Task { await viewModel.runTaskNow(task) }
        } label: {
            Label("Run Now", systemImage: "play.fill")
        }

        Divider()

        Button {
            Task { await viewModel.toggleTaskEnabled(task) }
        } label: {
            if task.isEnabled {
                Label("Disable", systemImage: "pause.fill")
            } else {
                Label("Enable", systemImage: "checkmark")
            }
        }

        Button {
            onEdit(task)
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            Task { await viewModel.deleteTask(task) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tasks", systemImage: "calendar.badge.exclamationmark")
        } description: {
            if !viewModel.searchText.isEmpty {
                Text("No tasks match your search")
            } else if hasActiveFilters {
                Text("No tasks match the selected filters")
            } else {
                Text("Create a new task to get started")
            }
        } actions: {
            if viewModel.searchText.isEmpty && !hasActiveFilters {
                Button("Create Task") {
                    NotificationCenter.default.post(name: .createNewTask, object: nil)
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


struct StatusFilterChip: View {
    let state: TaskState
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: state.systemImage)
                    .font(.caption2)
                Text(state.rawValue)
                    .font(.caption)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.2) : Color.clear)
            .foregroundColor(isSelected ? color : .secondary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? color.opacity(0.5) : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Filter by \(state.rawValue) tasks")
    }
}

#Preview {
    TaskListView(onAdd: {}, onEdit: { _ in }, onSelect: { _ in })
        .environmentObject(TaskListViewModel())
}
