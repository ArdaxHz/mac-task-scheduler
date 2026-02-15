//
//  HistoryView.swift
//  MacScheduler
//
//  View for displaying task execution history.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var viewModel: TaskListViewModel
    @State private var history: [TaskExecutionResult] = []
    @State private var selectedResult: TaskExecutionResult?
    @State private var showClearConfirmation = false
    @State private var filterTaskId: UUID?

    private let historyService = TaskHistoryService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Sticky filter bar
            filterBar
                .background(Color(.windowBackgroundColor))

            Divider()

            if filteredHistory.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .navigationTitle("Manual Execution History")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await loadHistory() }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Refresh execution history")

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .help("Delete all execution history")
                .disabled(history.isEmpty)
            }
        }
        .task {
            await loadHistory()
        }
        .confirmationDialog("Clear History", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                Task {
                    await historyService.clearAllHistory()
                    await loadHistory()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear all execution history? This action cannot be undone.")
        }
        .sheet(item: $selectedResult) { result in
            ExecutionDetailSheet(result: result, taskName: taskName(for: result.taskId))
        }
    }

    private var filteredHistory: [TaskExecutionResult] {
        if let taskId = filterTaskId {
            return history.filter { $0.taskId == taskId }
        }
        return history
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Text("Filter:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Task", selection: $filterTaskId) {
                Text("All Tasks").tag(UUID?.none)
                Divider()
                ForEach(viewModel.tasks) { task in
                    Text(task.name).tag(UUID?.some(task.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 150, maxWidth: 250)
            .help("Filter history by task")

            Spacer()

            Text("\(filteredHistory.count) execution\(filteredHistory.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var historyList: some View {
        List(filteredHistory) { result in
            HistoryRow(
                result: result,
                taskName: taskName(for: result.taskId)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedResult = result
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No History", systemImage: "clock.arrow.circlepath")
        } description: {
            if filterTaskId != nil {
                Text("No execution history for the selected task")
            } else {
                Text("Task execution history will appear here")
            }
        }
    }

    private func loadHistory() async {
        history = await historyService.getRecentHistory(limit: 100)
    }

    private func taskName(for taskId: UUID) -> String {
        viewModel.tasks.first { $0.id == taskId }?.name ?? "Unknown Task"
    }
}

struct HistoryRow: View {
    let result: TaskExecutionResult
    let taskName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.success ? .green : .red)
                .font(.title2)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(taskName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(result.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Text("Exit: \(result.exitCode)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(result.success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(4)
                    .fixedSize()

                Text(String(format: "%.2fs", result.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }
}

struct ExecutionDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: TaskExecutionResult
    let taskName: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    outputSection
                    errorSection
                }
                .padding()
            }
            .navigationTitle("Execution Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .help("Close execution details")
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var headerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(result.success ? .green : .red)

                    VStack(alignment: .leading) {
                        Text(taskName)
                            .font(.headline)
                        Text(result.success ? "Completed Successfully" : "Failed")
                            .foregroundColor(result.success ? .green : .red)
                    }

                    Spacer()
                }

                Divider()

                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Started")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(result.startTime.formatted(date: .abbreviated, time: .standard))
                    }

                    VStack(alignment: .leading) {
                        Text("Ended")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(result.endTime.formatted(date: .abbreviated, time: .standard))
                    }

                    VStack(alignment: .leading) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.3f seconds", result.duration))
                    }

                    VStack(alignment: .leading) {
                        Text("Exit Code")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(result.exitCode)")
                            .foregroundColor(result.exitCode == 0 ? .primary : .red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if !result.standardOutput.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Standard Output", systemImage: "text.alignleft")
                        .font(.headline)

                    ScrollView {
                        Text(result.standardOutput)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if !result.standardError.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Standard Error", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .foregroundColor(.red)

                    ScrollView {
                        Text(result.standardError)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
            }
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(TaskListViewModel())
}
