//
//  ScriptEditorView.swift
//  MacScheduler
//
//  View for editing shell scripts.
//

import SwiftUI

struct ScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let scriptPath: String
    let taskName: String
    @State private var scriptContent: String = ""
    @State private var originalContent: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var hasChanges = false
    @State private var showSaveConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Script path header
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text(scriptPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()

                    Button {
                        NSWorkspace.shared.selectFile(scriptPath, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
                .padding()
                .background(Color(.textBackgroundColor))

                Divider()

                if isLoading {
                    Spacer()
                    ProgressView("Loading script...")
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Could not load script")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else {
                    // Script editor
                    TextEditor(text: $scriptContent)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(.textBackgroundColor))
                        .onChange(of: scriptContent) { _, newValue in
                            hasChanges = newValue != originalContent
                        }
                }
            }
            .navigationTitle("Edit Script: \(taskName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            showSaveConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .help("Discard changes and close")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScript()
                    }
                    .disabled(!hasChanges)
                    .help("Save script to disk")
                }

                ToolbarItemGroup {
                    Button {
                        scriptContent = originalContent
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!hasChanges)
                    .help("Revert to last saved version")

                    Button {
                        openInExternalEditor()
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                    .help("Open script in default text editor")
                }
            }
            .confirmationDialog("Unsaved Changes", isPresented: $showSaveConfirmation) {
                Button("Save") {
                    saveScript()
                    dismiss()
                }
                Button("Discard", role: .destructive) {
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You have unsaved changes. Do you want to save them?")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            loadScript()
        }
    }

    private func loadScript() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
                DispatchQueue.main.async {
                    self.scriptContent = content
                    self.originalContent = content
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func saveScript() {
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            originalContent = scriptContent
            hasChanges = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func openInExternalEditor() {
        let url = URL(fileURLWithPath: scriptPath)
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ScriptEditorView(scriptPath: "/Users/test/script.sh", taskName: "Test Script")
}
