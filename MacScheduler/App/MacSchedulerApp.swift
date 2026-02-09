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
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    NotificationCenter.default.post(name: .createNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

extension Notification.Name {
    static let createNewTask = Notification.Name("createNewTask")
}
