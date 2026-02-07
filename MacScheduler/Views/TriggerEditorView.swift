//
//  TriggerEditorView.swift
//  MacScheduler
//
//  View for configuring calendar-based triggers.
//

import SwiftUI

struct TriggerEditorView: View {
    @Binding var minute: Int
    @Binding var hour: Int
    @Binding var day: Int?
    @Binding var weekday: Int?
    @Binding var month: Int?

    @State private var scheduleType: ScheduleType = .daily

    enum ScheduleType: String, CaseIterable {
        case everyMinute = "Every Minute"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        case custom = "Custom"
    }

    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private let months = ["January", "February", "March", "April", "May", "June",
                         "July", "August", "September", "October", "November", "December"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Schedule Type", selection: $scheduleType) {
                ForEach(ScheduleType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .help(scheduleTypeTooltip)
            .onChange(of: scheduleType) { _, newValue in
                updateDefaults(for: newValue)
            }

            switch scheduleType {
            case .everyMinute:
                Text("Task will run every minute")
                    .font(.caption)
                    .foregroundColor(.secondary)

            case .hourly:
                HStack {
                    Text("At minute")
                    TextField("00", value: $minute, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .help("The minute of each hour when the task runs (0-59)")
                    Text("of every hour")
                        .foregroundColor(.secondary)
                }

            case .daily:
                HStack {
                    Text("At")
                    TextField("00", value: $hour, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .help("Hour of the day in 24-hour format (0-23)")
                    Text(":")
                    TextField("00", value: $minute, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .help("Minute of the hour (0-59)")
                    Text("every day")
                        .foregroundColor(.secondary)
                }

            case .weekly:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("On")
                        Picker("Weekday", selection: Binding(
                            get: { weekday ?? 0 },
                            set: { weekday = $0 }
                        )) {
                            ForEach(0..<7) { d in
                                Text(weekdays[d]).tag(d)
                            }
                        }
                        .frame(width: 140)
                        .help("Day of the week when the task runs")
                    }

                    HStack {
                        Text("At")
                        TextField("00", value: $hour, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("Hour of the day in 24-hour format (0-23)")
                        Text(":")
                        TextField("00", value: $minute, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("Minute of the hour (0-59)")
                    }
                }

            case .monthly:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("On day")
                        TextField("1", value: Binding(
                            get: { day ?? 1 },
                            set: { day = $0 }
                        ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("Day of the month when the task runs (1-31)")
                        Text("of every month")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("At")
                        TextField("00", value: $hour, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("Hour of the day in 24-hour format (0-23)")
                        Text(":")
                        TextField("00", value: $minute, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("Minute of the hour (0-59)")
                    }
                }

            case .custom:
                customScheduleView
            }

            previewText
        }
    }

    private var customScheduleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Minute:")
                    .frame(width: 80, alignment: .leading)
                TextField("0-59", value: $minute, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .help("Minute of the hour when the task runs (0-59)")
            }

            HStack {
                Text("Hour:")
                    .frame(width: 80, alignment: .leading)
                TextField("0-23", value: $hour, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .help("Hour of the day in 24-hour format (0-23)")
            }

            HStack {
                Text("Day:")
                    .frame(width: 80, alignment: .leading)
                Toggle("Specific day", isOn: Binding(
                    get: { day != nil },
                    set: { day = $0 ? 1 : nil }
                ))
                .help("Enable to restrict the task to a specific day of the month")
                if day != nil {
                    TextField("1-31", value: Binding(
                        get: { day ?? 1 },
                        set: { day = $0 }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .help("Day of the month (1-31)")
                }
            }

            HStack {
                Text("Weekday:")
                    .frame(width: 80, alignment: .leading)
                Toggle("Specific weekday", isOn: Binding(
                    get: { weekday != nil },
                    set: { weekday = $0 ? 0 : nil }
                ))
                .help("Enable to restrict the task to a specific day of the week")
                if weekday != nil {
                    Picker("Weekday", selection: Binding(
                        get: { weekday ?? 0 },
                        set: { weekday = $0 }
                    )) {
                        ForEach(0..<7) { d in
                            Text(weekdays[d]).tag(d)
                        }
                    }
                    .frame(width: 140)
                    .help("Day of the week when the task runs")
                }
            }

            HStack {
                Text("Month:")
                    .frame(width: 80, alignment: .leading)
                Toggle("Specific month", isOn: Binding(
                    get: { month != nil },
                    set: { month = $0 ? 1 : nil }
                ))
                .help("Enable to restrict the task to a specific month")
                if month != nil {
                    Picker("Month", selection: Binding(
                        get: { month ?? 1 },
                        set: { month = $0 }
                    )) {
                        ForEach(1...12, id: \.self) { m in
                            Text(months[m - 1]).tag(m)
                        }
                    }
                    .frame(width: 140)
                    .help("Month when the task runs")
                }
            }
        }
    }

    private var previewText: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
            Text(schedulePreview)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var schedulePreview: String {
        let schedule = CalendarSchedule(
            minute: minute,
            hour: hour,
            day: day,
            weekday: weekday,
            month: month
        )
        return schedule.displayString
    }

    private var scheduleTypeTooltip: String {
        switch scheduleType {
        case .everyMinute: return "Run the task once every minute"
        case .hourly: return "Run the task once per hour at a specific minute"
        case .daily: return "Run the task once per day at a specific time"
        case .weekly: return "Run the task once per week on a specific day and time"
        case .monthly: return "Run the task once per month on a specific day and time"
        case .custom: return "Configure each schedule field individually"
        }
    }

    private func updateDefaults(for type: ScheduleType) {
        switch type {
        case .everyMinute:
            day = nil
            weekday = nil
            month = nil
        case .hourly:
            minute = 0
            day = nil
            weekday = nil
            month = nil
        case .daily:
            day = nil
            weekday = nil
            month = nil
        case .weekly:
            weekday = weekday ?? 1
            day = nil
            month = nil
        case .monthly:
            day = day ?? 1
            weekday = nil
            month = nil
        case .custom:
            break
        }
    }
}

#Preview {
    Form {
        TriggerEditorView(
            minute: .constant(0),
            hour: .constant(9),
            day: .constant(nil),
            weekday: .constant(nil),
            month: .constant(nil)
        )
    }
    .formStyle(.grouped)
}
