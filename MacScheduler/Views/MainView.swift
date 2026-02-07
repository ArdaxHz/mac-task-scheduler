//
//  MainView.swift
//  MacScheduler
//
//  Main window with sidebar navigation.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var viewModel: TaskListViewModel
    @State private var showingEditor = false
    @State private var editingTask: ScheduledTask?
    @State private var selectedNavItem: NavigationItem = .allTasks

    enum NavigationItem: Hashable {
        case allTasks
        case history
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentView
        } detail: {
            detailView
        }
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $showingEditor) {
            TaskEditorView(task: editingTask) { task in
                if editingTask != nil {
                    Task { await viewModel.updateTask(task) }
                } else {
                    Task { await viewModel.addTask(task) }
                }
            }
            .id(editingTask?.id ?? UUID())
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewTask)) { _ in
            editingTask = nil
            showingEditor = true
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        .toolbar {
            ToolbarItem {
                Button {
                    editingTask = nil
                    showingEditor = true
                } label: {
                    Label("Add Task", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedNavItem {
        case .allTasks:
            TaskListView(
                onEdit: { task in
                    editingTask = task
                    showingEditor = true
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
                editingTask = task
                showingEditor = true
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
