//
//  TaskTrigger.swift
//  MacScheduler
//
//  Defines the trigger types for scheduled tasks.
//

import Foundation

enum TriggerType: String, Codable, CaseIterable {
    case calendar = "Calendar"
    case interval = "Interval"
    case atLogin = "At Login"
    case atStartup = "At Startup"
    case onDemand = "On Demand"

    var description: String {
        switch self {
        case .calendar: return "Run on a specific schedule"
        case .interval: return "Run at regular intervals"
        case .atLogin: return "Run when user logs in"
        case .atStartup: return "Run when system starts"
        case .onDemand: return "Run only when manually triggered"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: return "calendar"
        case .interval: return "timer"
        case .atLogin: return "person.badge.key"
        case .atStartup: return "power"
        case .onDemand: return "hand.tap"
        }
    }

    var supportsLaunchd: Bool {
        return true
    }

    var supportsCron: Bool {
        switch self {
        case .calendar: return true
        case .interval, .atLogin, .atStartup, .onDemand: return false
        }
    }
}

struct CalendarSchedule: Codable, Equatable {
    var minute: Int?
    var hour: Int?
    var day: Int?
    var weekday: Int?
    var month: Int?

    init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil,
         weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    var displayString: String {
        var parts: [String] = []

        if let h = hour, let m = minute {
            parts.append(String(format: "%02d:%02d", h, m))
        } else if let h = hour {
            parts.append(String(format: "%02d:00", h))
        } else if let m = minute {
            parts.append("*:\(String(format: "%02d", m))")
        }

        if let d = day {
            parts.append("Day \(d)")
        }

        if let w = weekday {
            let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            if w >= 0 && w < weekdays.count {
                parts.append(weekdays[w])
            }
        }

        if let m = month {
            let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            if m >= 1 && m <= 12 {
                parts.append(months[m])
            }
        }

        return parts.isEmpty ? "Every minute" : parts.joined(separator: ", ")
    }

    func toCronExpression() -> String {
        let minStr = minute.map { String($0) } ?? "*"
        let hourStr = hour.map { String($0) } ?? "*"
        let dayStr = day.map { String($0) } ?? "*"
        let monthStr = month.map { String($0) } ?? "*"
        let weekdayStr = weekday.map { String($0) } ?? "*"

        return "\(minStr) \(hourStr) \(dayStr) \(monthStr) \(weekdayStr)"
    }
}

struct TaskTrigger: Codable, Equatable, Identifiable {
    let id: UUID
    var type: TriggerType
    var calendarSchedule: CalendarSchedule?
    var intervalSeconds: Int?
    var repeatCount: Int?
    var startDate: Date?
    var endDate: Date?

    init(id: UUID = UUID(),
         type: TriggerType = .onDemand,
         calendarSchedule: CalendarSchedule? = nil,
         intervalSeconds: Int? = nil,
         repeatCount: Int? = nil,
         startDate: Date? = nil,
         endDate: Date? = nil) {
        self.id = id
        self.type = type
        self.calendarSchedule = calendarSchedule
        self.intervalSeconds = intervalSeconds
        self.repeatCount = repeatCount
        self.startDate = startDate
        self.endDate = endDate
    }

    var displayString: String {
        switch type {
        case .calendar:
            return calendarSchedule?.displayString ?? "No schedule set"
        case .interval:
            guard let seconds = intervalSeconds else { return "No interval set" }
            if seconds < 60 {
                return "Every \(seconds) second\(seconds == 1 ? "" : "s")"
            } else if seconds < 3600 {
                let minutes = seconds / 60
                return "Every \(minutes) minute\(minutes == 1 ? "" : "s")"
            } else if seconds < 86400 {
                let hours = seconds / 3600
                return "Every \(hours) hour\(hours == 1 ? "" : "s")"
            } else {
                let days = seconds / 86400
                return "Every \(days) day\(days == 1 ? "" : "s")"
            }
        case .atLogin:
            return "When user logs in"
        case .atStartup:
            return "When system starts"
        case .onDemand:
            return "Manual trigger only"
        }
    }

    func validate() -> [String] {
        var errors: [String] = []

        switch type {
        case .calendar:
            if let schedule = calendarSchedule {
                if let minute = schedule.minute, (minute < 0 || minute > 59) {
                    errors.append("Minute must be between 0 and 59")
                }
                if let hour = schedule.hour, (hour < 0 || hour > 23) {
                    errors.append("Hour must be between 0 and 23")
                }
                if let day = schedule.day, (day < 1 || day > 31) {
                    errors.append("Day must be between 1 and 31")
                }
                if let weekday = schedule.weekday, (weekday < 0 || weekday > 6) {
                    errors.append("Weekday must be between 0 (Sunday) and 6 (Saturday)")
                }
                if let month = schedule.month, (month < 1 || month > 12) {
                    errors.append("Month must be between 1 and 12")
                }
            } else {
                errors.append("Calendar schedule is required")
            }
        case .interval:
            guard let seconds = intervalSeconds, seconds > 0 else {
                errors.append("Interval must be greater than 0")
                break
            }
        case .atLogin, .atStartup, .onDemand:
            break
        }

        if let start = startDate, let end = endDate, start > end {
            errors.append("Start date must be before end date")
        }

        return errors
    }

    static func calendar(minute: Int? = nil, hour: Int? = nil, day: Int? = nil,
                        weekday: Int? = nil, month: Int? = nil) -> TaskTrigger {
        TaskTrigger(type: .calendar,
                   calendarSchedule: CalendarSchedule(minute: minute, hour: hour,
                                                      day: day, weekday: weekday, month: month))
    }

    static func interval(seconds: Int) -> TaskTrigger {
        TaskTrigger(type: .interval, intervalSeconds: seconds)
    }

    static var atLogin: TaskTrigger {
        TaskTrigger(type: .atLogin)
    }

    static var atStartup: TaskTrigger {
        TaskTrigger(type: .atStartup)
    }

    static var onDemand: TaskTrigger {
        TaskTrigger(type: .onDemand)
    }
}
