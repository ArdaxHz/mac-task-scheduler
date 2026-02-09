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
    static let dangerousEnvVars: Set<String> = [
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FORCE_FLAT_NAMESPACE",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "BASH_ENV",
        "ENV",
        "CDPATH",
        "GLOBIGNORE",
        "SHELLOPTS",
        "BASHOPTS",
        "PROMPT_COMMAND",
    ]

    func generate(for task: ScheduledTask) -> String {
        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escapeXML(task.launchdLabel))</string>

        """

        plist += generateProgramSection(for: task)
        plist += generateTriggerSection(for: task)
        plist += generateOptionsSection(for: task)
        plist += generateMetadataSection(for: task)

        plist += """
        </dict>
        </plist>
        """

        return plist
    }

    private func generateProgramSection(for task: ScheduledTask) -> String {
        var section = ""

        switch task.action.type {
        case .executable:
            if task.action.arguments.isEmpty {
                section += """
                    <key>Program</key>
                    <string>\(escapeXML(task.action.path))</string>

                """
            } else {
                section += """
                    <key>ProgramArguments</key>
                    <array>
                        <string>\(escapeXML(task.action.path))</string>

                """
                for arg in task.action.arguments {
                    section += "        <string>\(escapeXML(arg))</string>\n"
                }
                section += "    </array>\n"
            }

        case .shellScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                section += """
                    <key>ProgramArguments</key>
                    <array>
                        <string>/bin/bash</string>
                        <string>-c</string>
                        <string>\(escapeXML(script))</string>
                    </array>

                """
            } else {
                section += """
                    <key>ProgramArguments</key>
                    <array>
                        <string>/bin/bash</string>
                        <string>\(escapeXML(task.action.path))</string>
                    </array>

                """
            }

        case .appleScript:
            if let script = task.action.scriptContent, !script.isEmpty {
                section += """
                    <key>ProgramArguments</key>
                    <array>
                        <string>/usr/bin/osascript</string>
                        <string>-e</string>
                        <string>\(escapeXML(script))</string>
                    </array>

                """
            } else {
                section += """
                    <key>ProgramArguments</key>
                    <array>
                        <string>/usr/bin/osascript</string>
                        <string>\(escapeXML(task.action.path))</string>
                    </array>

                """
            }
        }

        if let workDir = task.action.workingDirectory, !workDir.isEmpty {
            section += """
                <key>WorkingDirectory</key>
                <string>\(escapeXML(workDir))</string>

            """
        }

        let safeEnvVars = task.action.environmentVariables.filter { key, _ in
            !Self.dangerousEnvVars.contains(key.uppercased())
        }
        if !safeEnvVars.isEmpty {
            section += "    <key>EnvironmentVariables</key>\n    <dict>\n"
            for (key, value) in safeEnvVars {
                section += "        <key>\(escapeXML(key))</key>\n"
                section += "        <string>\(escapeXML(value))</string>\n"
            }
            section += "    </dict>\n"
        }

        return section
    }

    private func generateTriggerSection(for task: ScheduledTask) -> String {
        var section = ""

        switch task.trigger.type {
        case .calendar:
            if let schedule = task.trigger.calendarSchedule {
                section += "    <key>StartCalendarInterval</key>\n    <dict>\n"

                if let month = schedule.month {
                    section += "        <key>Month</key>\n        <integer>\(month)</integer>\n"
                }
                if let day = schedule.day {
                    section += "        <key>Day</key>\n        <integer>\(day)</integer>\n"
                }
                if let weekday = schedule.weekday {
                    section += "        <key>Weekday</key>\n        <integer>\(weekday)</integer>\n"
                }
                if let hour = schedule.hour {
                    section += "        <key>Hour</key>\n        <integer>\(hour)</integer>\n"
                }
                if let minute = schedule.minute {
                    section += "        <key>Minute</key>\n        <integer>\(minute)</integer>\n"
                }

                section += "    </dict>\n"
            }

        case .interval:
            if let seconds = task.trigger.intervalSeconds {
                section += """
                    <key>StartInterval</key>
                    <integer>\(seconds)</integer>

                """
            }

        case .atLogin, .atStartup:
            section += """
                <key>RunAtLoad</key>
                <true/>

            """

        case .onDemand:
            break
        }

        return section
    }

    private func generateOptionsSection(for task: ScheduledTask) -> String {
        var section = ""

        if task.runAtLoad && task.trigger.type != .atLogin && task.trigger.type != .atStartup {
            section += """
                <key>RunAtLoad</key>
                <true/>

            """
        }

        if task.keepAlive {
            section += """
                <key>KeepAlive</key>
                <true/>

            """
        }

        if let outPath = task.standardOutPath, !outPath.isEmpty {
            section += """
                <key>StandardOutPath</key>
                <string>\(escapeXML(outPath))</string>

            """
        }

        if let errPath = task.standardErrorPath, !errPath.isEmpty {
            section += """
                <key>StandardErrorPath</key>
                <string>\(escapeXML(errPath))</string>

            """
        }

        return section
    }

    private func generateMetadataSection(for task: ScheduledTask) -> String {
        var section = ""

        if !task.name.isEmpty {
            section += """
                <key>MacSchedulerName</key>
                <string>\(escapeXML(task.name))</string>

            """
        }

        if !task.description.isEmpty {
            section += """
                <key>MacSchedulerDescription</key>
                <string>\(escapeXML(task.description))</string>

            """
        }

        return section
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
