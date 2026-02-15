# Mac Task Scheduler

A native macOS application for creating, viewing, editing, and managing scheduled tasks using launchd and cron backends. Discover and monitor all system and user tasks in one place.

**Author:** [Ardax](https://github.com/ArdaxHz)

## Features

### Task Discovery
- Automatically discovers all launchd tasks from:
  - `~/Library/LaunchAgents/` (user agents)
  - `/Library/LaunchAgents/` (system agents)
  - `/Library/LaunchDaemons/` (system daemons)
  - `/System/Library/LaunchAgents/` (Apple system agents)
  - `/System/Library/LaunchDaemons/` (Apple system daemons)
- Discovers cron tasks (both app-created and manually added)
- Live status from `launchctl`: running, enabled, disabled, or error states

### Task Management
- Create, edit, and delete scheduled tasks
- Install tasks as **User Agents**, **System Agents**, or **System Daemons**
- System-level operations prompt for admin credentials automatically
- Enable/disable tasks (load/unload from launchd)
- Run tasks immediately (manual trigger)
- Specify the user account for system daemons (`UserName` plist key)

### Trigger Types

#### launchd Backend (Recommended)
- **Calendar**: Run on specific dates/times or recurring schedules
- **Interval**: Run every N seconds/minutes/hours/days
- **At Login**: Run when user logs in
- **At Startup**: Run when system boots
- **On Demand**: Manual trigger only

#### cron Backend
- Standard cron expressions
- Visual schedule builder

### Task Actions
- Run executables and applications
- Run shell scripts (inline or from file)
- Run AppleScript (inline or from file)
- Built-in script editor for file-based scripts

### Status Monitoring
- **Running**: Shows uptime duration and process start time
- **Error**: Shows exit code and when the error occurred
- **Enabled/Disabled**: Current launchd registration state
- Run count and failure count from launchctl

### Filtering & Search
- Search by task name, description, or label
- Filter by status (Enabled, Disabled, Running, Error)
- Filter by scope (Editable / Read-Only)
- Filter by trigger type
- Filter by backend (launchd / cron)
- Filter by last run status

### Execution History
- Track all task executions triggered via the app
- View stdout/stderr output for each run
- Success/failure status with exit codes
- Execution duration
- Per-task history with "View All" popup

### UI
- Two-column layout with collapsible, resizable detail panel
- Task table with sortable columns
- Context menus for quick actions
- Auto-update checker (GitHub Releases)

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ for building

## Installation

### From Release
1. Download the latest `.zip` from [Releases](https://github.com/ArdaxHz/mac-task-scheduler/releases)
2. Unzip and move `Mac Task Scheduler.app` to `/Applications/`
3. Launch the app

### From Source
1. Clone the repository
2. Open `MacScheduler.xcodeproj` in Xcode
3. Build and run (Cmd+R)

## Usage

### Creating a Task

1. Click the **+** button or press **Cmd+N**
2. Enter a task name and optional description
3. Choose a backend (launchd recommended)
4. Choose a location:
   - **User Agent**: Runs as your user at login (`~/Library/LaunchAgents/`)
   - **System Agent**: Runs for all users at login (`/Library/LaunchAgents/`)
   - **System Daemon**: Runs at boot (`/Library/LaunchDaemons/`)
5. Configure the action (Executable, Shell Script, or AppleScript)
6. Configure the trigger and schedule
7. Click **Save** (admin password required for system locations)

### Managing Tasks

- **Enable/Disable**: Click the toggle or use the context menu
- **Run Now**: Click the play button to run immediately
- **Edit**: Double-click or select Edit from context menu
- **Delete**: Use the context menu or toolbar button
- **Load/Unload**: Directly control launchd registration

## Stateless Design

The app has **no internal database**. All task data is read directly from live LaunchAgent/LaunchDaemon plist files and crontab entries. Tasks created by the app are standard native launchd/cron tasks -- if the app is deleted, all tasks continue to run normally.

Custom metadata (task names and descriptions) is stored as `MacSchedulerName` and `MacSchedulerDescription` keys inside plist files (launchd ignores unknown keys).

## Data Locations

| Data | Path |
|------|------|
| User Launch Agents | `~/Library/LaunchAgents/` |
| System Launch Agents | `/Library/LaunchAgents/` |
| System Daemons | `/Library/LaunchDaemons/` |
| Execution History | `~/Library/Application Support/MacScheduler/history.json` |
| Scripts | `~/Library/Scripts/` (configurable) |

## Architecture

```
MacScheduler/
├── App/                    # App entry point
├── Models/                 # Data models
│   ├── ScheduledTask       # Core task model with TaskLocation
│   ├── TaskTrigger         # Trigger configuration
│   ├── TaskAction          # Action configuration
│   └── TaskStatus          # Execution status (state, exit codes, uptime)
├── Services/               # Backend services
│   ├── SchedulerService    # Protocol for backends
│   ├── LaunchdService      # launchd integration (with elevated privilege support)
│   ├── CronService         # cron integration
│   └── TaskHistoryService  # History tracking (actor-based)
├── Views/                  # SwiftUI views
├── ViewModels/             # View state management
└── Utilities/              # PlistGenerator, ShellExecutor, etc.
```

## License

MIT License
