# Mac Task Scheduler

A native macOS application for managing scheduled tasks. Discover, create, edit, and monitor launchd agents, cron jobs, Docker containers, and virtual machines -- all from one place.

**Author:** [Ardax](https://github.com/ArdaxHz)

## Installation

### From Release (Recommended)
1. Download the latest `.dmg` from [Releases](https://github.com/ArdaxHz/mac-task-scheduler/releases)
2. Open the DMG and drag **Mac Task Scheduler** to `/Applications/`
3. Launch the app

All releases are signed and notarized with Apple Developer ID.

### From Source
```bash
git clone https://github.com/ArdaxHz/mac-task-scheduler.git
cd mac-task-scheduler
xcodebuild -project MacTaskScheduler.xcodeproj -scheme MacTaskScheduler -configuration Release build
open build/Release/Mac\ Task\ Scheduler.app
```

Requires macOS 14.0 (Sonoma) or later and Xcode 15.0+.

---

## Features

### Task Discovery

The app automatically discovers all scheduled tasks on your Mac:

| Source | Path | Permissions |
|--------|------|-------------|
| User Agents | `~/Library/LaunchAgents/` | Read-Write |
| System Agents | `/Library/LaunchAgents/` | Read-Only |
| System Daemons | `/Library/LaunchDaemons/` | Read-Only |
| Apple System Agents | `/System/Library/LaunchAgents/` | Read-Only |
| Apple System Daemons | `/System/Library/LaunchDaemons/` | Read-Only |
| Cron Jobs | User crontab | Read-Write |
| Docker Containers | Docker CLI | Read-Write |
| Virtual Machines | Hypervisor CLIs | Read-Only |

### Task Management

- **Create** new launchd or cron tasks with a full configuration form
- **Edit** existing tasks (a snapshot is saved automatically before each edit)
- **Delete** tasks (moved to trash for recovery)
- **Enable/Disable** tasks (load/unload from launchd)
- **Run Now** to trigger any task immediately
- **Bulk operations** to load or unload all tasks at once
- **Restore** deleted tasks from the trash
- **Revert** to any previous version from the version history

System-level operations (system agents and daemons) prompt for admin credentials automatically.

### Scheduler Backends

#### Editable Backends

**launchd** (Recommended) -- the native macOS scheduler, supports all trigger types and the most configuration options.

**cron** -- traditional Unix scheduler with standard cron expressions and a visual schedule builder.

#### Discovery-Only Backends

**Docker** -- discovers and manages containers from Docker Desktop, OrbStack, Colima, or Rancher Desktop.

**Virtual Machines** -- discovers VMs from Parallels Desktop, VirtualBox, UTM, and VMware Fusion.

### Trigger Types

| Trigger | launchd | cron | Description |
|---------|:-------:|:----:|-------------|
| Calendar | x | x | Run on specific dates/times or recurring schedules |
| Interval | x | | Run every N seconds, minutes, hours, or days |
| At Login | x | | Run when the user logs in |
| At Startup | x | | Run when the system boots |
| On Demand | x | | Manual trigger only |

Schedule presets are available for common patterns: every minute, hourly, daily, weekly, and monthly.

### Task Actions

| Action | Description |
|--------|-------------|
| Executable | Run any binary or application |
| Shell Script | Run bash/sh/zsh scripts, inline or from a file |
| AppleScript | Run AppleScript, inline or from a file |

Each action supports arguments, a working directory, environment variables, and stdout/stderr redirection.

A built-in **script editor** lets you write and edit scripts directly in the app.

### Task Locations (launchd)

| Location | Runs As | When | Path |
|----------|---------|------|------|
| User Agent | Current user | At login | `~/Library/LaunchAgents/` |
| System Agent | All users | At login | `/Library/LaunchAgents/` |
| System Daemon | Configurable | At boot | `/Library/LaunchDaemons/` |

---

## Docker Container Management

The app discovers Docker containers and displays:

- Container status, image, ports, volumes, environment variables, and network mode
- Launch origin (Docker Compose, Boot, Manual, Dockerfile, or Command)
- Runtime detection (Docker Desktop, OrbStack, Colima, Rancher)

**Container operations:**
- Create and configure new containers (image, ports, env vars, volumes, restart policy, network, command)
- Import `.env` files via file picker or drag-and-drop
- Remove containers with options to cascade volumes and images
- Docker Compose `down` for Compose-managed projects

**Offline support:** When Docker is unavailable, cached container data is shown with a stale indicator. Actions are disabled until Docker comes back online.

---

## Virtual Machine Discovery

The app discovers VMs from installed hypervisors (read-only):

| Hypervisor | Information Shown |
|------------|-------------------|
| Parallels Desktop | Name, state, OS type, CPU, memory |
| VirtualBox | Name, state, OS type, CPU, memory |
| UTM | Name, state |
| VMware Fusion | Name, state |

Discovery is non-blocking -- if a hypervisor isn't installed, it is silently skipped.

---

## Status Monitoring

| State | Indicator | Details |
|-------|-----------|---------|
| Running | Green | Uptime duration, process start time |
| Enabled | Blue | Loaded in launchd, will run on schedule |
| Disabled | Grey | Not loaded, won't run |
| Error | Red | Exit code, failure timestamp |

Additional metrics: run count, failure count, last run time, and last exit code.

---

## Execution History

Every task execution triggered via the app is recorded:

- Start and end timestamps
- Exit code and success/failure status
- Full stdout/stderr output
- Execution duration
- Per-task filtering and "View All" popup

History is stored at `~/Library/Application Support/MacScheduler/history.json`.

---

## Version History & Trash

### Version History

Snapshots are saved automatically before every edit and delete. You can browse the full history of changes to any task and revert to any previous version.

- Up to 50 snapshots per task, 500 total
- Follows the configured log retention period
- Stored at `~/Library/Application Support/MacScheduler/Snapshots/`

### Trash

Deleted tasks are moved to the trash instead of being permanently removed. From the trash you can:

- **Restore** a task to reinstall its plist or cron entry
- **Permanently delete** to remove all snapshots and execution history
- **Empty trash** to bulk-delete everything

---

## Filtering & Search

**Search** across task names, descriptions, and launchd labels.

**Filter by:**
- Backend: launchd, cron, Docker, Parallels, VirtualBox, UTM, VMware
- Status: Enabled, Disabled, Running, Error (multi-select in the sidebar)
- Trigger type: Calendar, Interval, At Login, At Startup, On Demand
- Last run: All, Has Run, Never Run
- Ownership: All, Editable, Read-Only
- Location: All, User Agent, System Agent, System Daemon

Status counts are shown in the sidebar for quick reference.

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + N` | New Task |
| `Cmd + R` | Refresh All |
| `Cmd + I` | Toggle Detail Panel |
| `Cmd + ,` | Settings |
| `Cmd + E` | Edit Selected Task |
| `Shift + Cmd + R` | Run Selected Task Now |
| `Shift + Cmd + T` | Toggle Enable/Disable |
| `Cmd + Delete` | Delete Selected Task |
| `Cmd + ?` | Keyboard Shortcuts |

---

## Settings

### General
- **Default backend** -- choose launchd or cron for new tasks
- **Notifications** -- toggle task completion notifications

### Storage
- **Scripts directory** -- where file-based scripts are saved (default: `~/Library/Scripts/`)
- **Data locations** -- reference table of all app data paths

### Advanced
- **Log retention** -- 7, 14, 30, 90 days, or forever
- **Clear history** -- delete all execution history
- **Clear version history** -- purge all snapshots
- **Reset app** -- delete all app-created tasks and data

### About
- Version info and links
- Auto-update checker (compares against GitHub Releases)

---

## Data Locations

| Data | Path |
|------|------|
| User Launch Agents | `~/Library/LaunchAgents/` |
| System Launch Agents | `/Library/LaunchAgents/` |
| System Daemons | `/Library/LaunchDaemons/` |
| Execution History | `~/Library/Application Support/MacScheduler/history.json` |
| Version Snapshots | `~/Library/Application Support/MacScheduler/Snapshots/` |
| Docker Cache | `~/Library/Application Support/MacScheduler/docker-cache.json` |
| App Logs | `~/Library/Logs/MacScheduler/` |
| Scripts | `~/Library/Scripts/` (configurable) |

---

## Stateless Design

The app has **no internal database**. All task data is read directly from live plist files and crontab entries. Tasks created by the app are standard native launchd/cron tasks -- if the app is deleted, all scheduled tasks continue to run normally.

Custom metadata (task names and descriptions) is stored as `MacSchedulerName` and `MacSchedulerDescription` keys inside plist files. launchd ignores unknown keys, so this has no effect on task execution.

---

## Architecture

```
MacScheduler/
├── App/                          # App entry point
├── Models/                       # Data models
│   ├── ScheduledTask             # Core task model
│   ├── TaskTrigger               # Trigger configuration
│   ├── TaskAction                # Action configuration
│   ├── TaskStatus                # Runtime status
│   ├── TaskSnapshot              # Version history snapshot
│   ├── ContainerInfo             # Docker container metadata
│   └── VMInfo                    # Virtual machine metadata
├── Services/                     # Backend implementations
│   ├── SchedulerService          # Protocol (Strategy pattern)
│   ├── LaunchdService            # launchd plist management
│   ├── CronService               # crontab editing
│   ├── DockerService             # Docker CLI integration
│   ├── DockerCacheService        # Offline container caching
│   ├── ParallelsService          # Parallels VM discovery
│   ├── VirtualBoxService         # VirtualBox VM discovery
│   ├── UTMService                # UTM VM discovery
│   ├── VMwareFusionService       # VMware Fusion VM discovery
│   ├── TaskHistoryService        # Execution history (actor)
│   ├── TaskVersionService        # Snapshot management (actor)
│   └── UpdateService             # GitHub release checker
├── ViewModels/                   # MVVM state management
│   ├── TaskListViewModel         # Main task list
│   ├── TaskEditorViewModel       # Task creation/editing form
│   └── DockerEditorViewModel     # Docker container form
├── Views/                        # SwiftUI views
│   ├── MainView                  # Two-column layout with sidebar
│   ├── TaskListView              # Sortable task table
│   ├── TaskDetailView            # Task details panel
│   ├── TaskEditorView            # Task creation/editing
│   ├── DockerEditorView          # Docker container editor
│   ├── HistoryView               # Execution history
│   ├── TrashView                 # Deleted tasks
│   ├── VersionHistorySheet       # Version history browser
│   ├── SettingsView              # Preferences
│   └── ...                       # Trigger editor, script editor, etc.
└── Utilities/                    # Helpers
    ├── PlistGenerator            # XML plist generation
    ├── ShellExecutor             # Process execution (actor)
    ├── CronParser                # Cron expression parsing
    └── AppLogger                 # File-based daily logging
```

Zero external dependencies -- pure Swift/SwiftUI with Foundation.

---

## License

MIT License

Built by [Nevra](https://nevra.tech).
