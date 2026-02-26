//
//  MacSchedulerApp.swift
//  MacScheduler
//
//  A native macOS app for managing scheduled tasks using launchd and cron backends.
//

import SwiftUI

@main
struct MacSchedulerApp: App {
    @StateObject private var taskListViewModel = TaskListViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(taskListViewModel)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task { await TaskHistoryService.shared.flush() }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    AboutWindowController.shared.showWindow()
                } label: {
                    Label("About Mac Task Scheduler", systemImage: "info.circle")
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    NotificationCenter.default.post(name: .createNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()

                Button("Refresh All") {
                    NotificationCenter.default.post(name: .refreshAllTasks, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Toggle Detail Panel") {
                    NotificationCenter.default.post(name: .toggleDetailPanel, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Edit Task") {
                    NotificationCenter.default.post(name: .editSelectedTask, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Run Task Now") {
                    NotificationCenter.default.post(name: .runSelectedTask, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Toggle Task Enabled") {
                    NotificationCenter.default.post(name: .toggleSelectedTask, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Delete Task") {
                    NotificationCenter.default.post(name: .deleteSelectedTask, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Mac Task Scheduler Help") {
                    if let url = URL(string: "https://github.com/ArdaxHz/mac-scheduler/wiki") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Keyboard Shortcuts") {
                    KeyboardShortcutsWindowController.shared.showWindow()
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

// MARK: - About Window

/// Manages a singleton About panel shown from the app menu.
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 380)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Mac Task Scheduler"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

private struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    @State private var updateState: UpdateState = .idle
    @State private var availableUpdate: UpdateService.Release?

    private enum UpdateState {
        case idle, checking, upToDate, available, error
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Spacer().frame(height: 12)

            Text("Mac Task Scheduler")
                .font(.system(size: 16, weight: .bold))

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 2)

            Spacer().frame(height: 6)

            Text("by Ardax")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            // Links
            HStack(spacing: 16) {
                Button {
                    if let url = URL(string: "https://ardax.dev") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("ardax.dev", systemImage: "globe")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)

                Button {
                    if let url = URL(string: "https://github.com/ArdaxHz/mac-scheduler") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        GitHubMark()
                            .frame(width: 12, height: 12)
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.link)
            }
            .padding(.top, 8)

            Text("If you find this app useful, consider supporting the author.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            Divider()
                .padding(.vertical, 12)

            // Update check
            updateSection
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(width: 320, height: 380)
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 8) {
            HStack {
                switch updateState {
                case .idle:
                    EmptyView()
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("You're up to date")
                        .font(.system(size: 11))
                case .available:
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 12))
                    if let update = availableUpdate {
                        Text("Version \(update.version) available")
                            .font(.system(size: 11))
                            .fontWeight(.medium)
                    }
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text("Could not check for updates")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Check for Updates") {
                    checkForUpdate()
                }
                .controlSize(.small)
                .disabled(updateState == .checking)

                if case .available = updateState, let update = availableUpdate {
                    Button("Download") {
                        if let url = URL(string: update.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }

                Spacer()
            }
        }
    }

    private func checkForUpdate() {
        updateState = .checking
        Task {
            if let release = await UpdateService.shared.checkForUpdate() {
                availableUpdate = release
                updateState = .available
            } else {
                updateState = .upToDate
            }
        }
    }
}

// MARK: - Keyboard Shortcuts Window

final class KeyboardShortcutsWindowController {
    static let shared = KeyboardShortcutsWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = KeyboardShortcutsView()
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 400)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

private struct KeyboardShortcutsView: View {
    private struct ShortcutGroup {
        let title: String
        let shortcuts: [(key: String, description: String)]
    }

    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "General", shortcuts: [
            ("⌘ N", "New Task"),
            ("⌘ R", "Refresh All"),
            ("⌘ I", "Toggle Detail Panel"),
            ("⌘ ,", "Settings"),
            ("⌘ ?", "Help"),
        ]),
        ShortcutGroup(title: "Selected Task", shortcuts: [
            ("⌘ E", "Edit Task"),
            ("⇧⌘ R", "Run Task Now"),
            ("⇧⌘ T", "Toggle Enabled/Disabled"),
            ("⌘ ⌫", "Delete Task"),
        ]),
        ShortcutGroup(title: "Window", shortcuts: [
            ("⌘ W", "Close Window"),
            ("⌘ Q", "Quit"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 8)
                }

                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.bottom, 6)

                ForEach(Array(group.shortcuts.enumerated()), id: \.offset) { _, shortcut in
                    HStack {
                        Text(shortcut.key)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 60, alignment: .leading)
                            .foregroundColor(.accentColor)
                        Text(shortcut.description)
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 400)
    }
}

/// GitHub mark rendered as a SwiftUI shape (the Invertocat silhouette).
private struct GitHubMark: View {
    var body: some View {
        Image(systemName: "cat.fill")
            .resizable()
            .scaledToFit()
    }
}

extension Notification.Name {
    static let createNewTask = Notification.Name("createNewTask")
    static let refreshAllTasks = Notification.Name("refreshAllTasks")
    static let toggleDetailPanel = Notification.Name("toggleDetailPanel")
    static let editSelectedTask = Notification.Name("editSelectedTask")
    static let runSelectedTask = Notification.Name("runSelectedTask")
    static let toggleSelectedTask = Notification.Name("toggleSelectedTask")
    static let deleteSelectedTask = Notification.Name("deleteSelectedTask")
}
