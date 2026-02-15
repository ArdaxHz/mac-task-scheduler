//
//  PlistGenerator.swift
//  MacScheduler
//
//  Generates launchd plist files for scheduled tasks.
//

import Foundation

class PlistGenerator {

    /// Environment variable names that must never be set via task configuration
    /// as they enable code injection or privilege escalation.
    /// All entries are uppercased; comparisons must use isDangerousEnvVar() for
    /// case-insensitive matching (env vars are case-sensitive on macOS, so an
    /// attacker could bypass with mixed case like "Dyld_Insert_Libraries").
    static let dangerousEnvVars: Set<String> = [
        // macOS dyld injection
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FORCE_FLAT_NAMESPACE",
        "DYLD_PRINT_LIBRARIES",
        // Linux linker injection
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        // Shell injection
        "BASH_ENV",
        "ENV",
        "CDPATH",
        "GLOBIGNORE",
        "SHELLOPTS",
        "BASHOPTS",
        "PROMPT_COMMAND",
        "IFS",
        // Interpreter hijacking
        "PYTHONPATH",
        "PYTHONSTARTUP",
        "RUBYLIB",
        "RUBYOPT",
        "PERL5LIB",
        "PERL5OPT",
        "NODE_OPTIONS",
        "JAVA_TOOL_OPTIONS",
        // Compiler/build hijacking
        "LDFLAGS",
        "CPPFLAGS",
        "CFLAGS",
    ]

    /// Case-insensitive check against the blocklist.
    static func isDangerousEnvVar(_ name: String) -> Bool {
        dangerousEnvVars.contains(name.uppercased())
    }

    func generate(for task: ScheduledTask) -> String {
        // Use array of parts + joined for O(n) instead of O(n²) string concatenation
        var parts: [String] = []
        parts.reserveCapacity(32)

        parts.append("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escapeXML(task.launchdLabel))</string>
        """)

        appendProgramSection(for: task, to: &parts)
        appendTriggerSection(for: task, to: &parts)
        appendOptionsSection(for: task, to: &parts)
        appendMetadataSection(for: task, to: &parts)

        parts.append("""
        </dict>
        </plist>
        """)

        return parts.joined(separator: "\n")
    }

    private func appendProgramSection(for task: ScheduledTask, to parts: inout [String]) {
        switch task.action.type {
        case .executable:
            if task.action.arguments.isEmpty {
                parts.append("    <key>Program</key>")
                parts.append("    <string>\(escapeXML(task.action.path))</string>")
            } else {
                parts.append("    <key>ProgramArguments</key>")
                parts.append("    <array>")
                parts.append("        <string>\(escapeXML(task.action.path))</string>")
                for arg in task.action.arguments {
                    parts.append("        <string>\(escapeXML(arg))</string>")
                }
                parts.append("    </array>")
            }

        case .shellScript:
            parts.append("    <key>ProgramArguments</key>")
            parts.append("    <array>")
            parts.append("        <string>/bin/bash</string>")
            if let script = task.action.scriptContent, !script.isEmpty {
                parts.append("        <string>-c</string>")
                parts.append("        <string>\(escapeXML(script))</string>")
            } else {
                parts.append("        <string>\(escapeXML(task.action.path))</string>")
            }
            parts.append("    </array>")

        case .appleScript:
            parts.append("    <key>ProgramArguments</key>")
            parts.append("    <array>")
            parts.append("        <string>/usr/bin/osascript</string>")
            if let script = task.action.scriptContent, !script.isEmpty {
                parts.append("        <string>-e</string>")
                parts.append("        <string>\(escapeXML(script))</string>")
            } else {
                parts.append("        <string>\(escapeXML(task.action.path))</string>")
            }
            parts.append("    </array>")
        }

        if let workDir = task.action.workingDirectory, !workDir.isEmpty {
            parts.append("    <key>WorkingDirectory</key>")
            parts.append("    <string>\(escapeXML(workDir))</string>")
        }

        let safeEnvVars = task.action.environmentVariables.filter { key, _ in
            !Self.isDangerousEnvVar(key)
        }
        if !safeEnvVars.isEmpty {
            parts.append("    <key>EnvironmentVariables</key>")
            parts.append("    <dict>")
            for (key, value) in safeEnvVars {
                parts.append("        <key>\(escapeXML(key))</key>")
                parts.append("        <string>\(escapeXML(value))</string>")
            }
            parts.append("    </dict>")
        }
    }

    private func appendTriggerSection(for task: ScheduledTask, to parts: inout [String]) {
        switch task.trigger.type {
        case .calendar:
            if let schedule = task.trigger.calendarSchedule {
                parts.append("    <key>StartCalendarInterval</key>")
                parts.append("    <dict>")
                if let month = schedule.month {
                    parts.append("        <key>Month</key>")
                    parts.append("        <integer>\(month)</integer>")
                }
                if let day = schedule.day {
                    parts.append("        <key>Day</key>")
                    parts.append("        <integer>\(day)</integer>")
                }
                if let weekday = schedule.weekday {
                    parts.append("        <key>Weekday</key>")
                    parts.append("        <integer>\(weekday)</integer>")
                }
                if let hour = schedule.hour {
                    parts.append("        <key>Hour</key>")
                    parts.append("        <integer>\(hour)</integer>")
                }
                if let minute = schedule.minute {
                    parts.append("        <key>Minute</key>")
                    parts.append("        <integer>\(minute)</integer>")
                }
                parts.append("    </dict>")
            }

        case .interval:
            if let seconds = task.trigger.intervalSeconds {
                parts.append("    <key>StartInterval</key>")
                parts.append("    <integer>\(seconds)</integer>")
            }

        case .atLogin, .atStartup:
            parts.append("    <key>RunAtLoad</key>")
            parts.append("    <true/>")

        case .onDemand:
            break
        }
    }

    private func appendOptionsSection(for task: ScheduledTask, to parts: inout [String]) {
        if task.runAtLoad && task.trigger.type != .atLogin && task.trigger.type != .atStartup {
            parts.append("    <key>RunAtLoad</key>")
            parts.append("    <true/>")
        }

        if task.keepAlive {
            parts.append("    <key>KeepAlive</key>")
            parts.append("    <true/>")
        }

        if let outPath = task.standardOutPath, !outPath.isEmpty {
            parts.append("    <key>StandardOutPath</key>")
            parts.append("    <string>\(escapeXML(outPath))</string>")
        }

        if let errPath = task.standardErrorPath, !errPath.isEmpty {
            parts.append("    <key>StandardErrorPath</key>")
            parts.append("    <string>\(escapeXML(errPath))</string>")
        }

        if let userName = task.userName, !userName.isEmpty {
            parts.append("    <key>UserName</key>")
            parts.append("    <string>\(escapeXML(userName))</string>")
        }
    }

    private func appendMetadataSection(for task: ScheduledTask, to parts: inout [String]) {
        if !task.name.isEmpty {
            parts.append("    <key>MacSchedulerName</key>")
            parts.append("    <string>\(escapeXML(task.name))</string>")
        }

        if !task.description.isEmpty {
            parts.append("    <key>MacSchedulerDescription</key>")
            parts.append("    <string>\(escapeXML(task.description))</string>")
        }
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
