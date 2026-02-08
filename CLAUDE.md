# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (debug)
xcodebuild -project MacScheduler.xcodeproj -scheme MacScheduler -configuration Debug build

# Build (release archive, unsigned — same as CI)
xcodebuild archive \
  -project MacScheduler.xcodeproj \
  -scheme MacScheduler \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/MacScheduler.xcarchive \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Launch the app (after debug build)
open build/Debug/Mac\ Task\ Scheduler.app
# or kill and relaunch if already running:
pkill -x "Mac Task Scheduler"; sleep 1; open build/Debug/Mac\ Task\ Scheduler.app
```

**After every code change**, rebuild and relaunch the app so the user can verify:
```bash
xcodebuild -project MacScheduler.xcodeproj -scheme MacScheduler -configuration Debug build 2>&1 | tail -5
pkill -x "Mac Task Scheduler"; sleep 1; open build/Debug/Mac\ Task\ Scheduler.app
```

There are no tests. The project has zero external dependencies — pure Swift/SwiftUI with Foundation.

**Targets:** macOS 14.0 (Sonoma)+, Xcode 15.0+, Swift 5.9+

## Architecture

MVVM with a protocol-based service layer for scheduler backends.

**Stateless design:** The app has NO internal database. All task data is read directly from live LaunchAgents/LaunchDaemons plist files and crontab. Tasks created by the app are standard native launchd/cron tasks — if the app is deleted, all tasks continue to run.

**Data flow:** `MacSchedulerApp` creates `TaskListViewModel` as a `@StateObject` and injects it via `.environmentObject()`. On init and refresh, the view model calls `discoverAllTasks()` which reads from:
- `~/Library/LaunchAgents/` (user agents, read-write)
- `/Library/LaunchAgents/` (system agents, read-only)
- `/Library/LaunchDaemons/` (system daemons, read-only)
- User crontab

**Custom metadata:** Task names and descriptions are stored as `MacSchedulerName` and `MacSchedulerDescription` keys inside plist files (launchd ignores unknown keys). For tasks without these keys, names are derived from the launchd label.

**Service layer** uses the Strategy pattern:
- `SchedulerService` protocol defines the backend interface (install/uninstall/enable/disable/runNow/discover)
- `LaunchdService` — writes plist files to `~/Library/LaunchAgents/`, manages via `launchctl`
- `CronService` — edits user crontab, tags entries with `# CronTask:<label>` comments
- `SchedulerServiceFactory` selects the appropriate service by `SchedulerBackend` enum
- `TaskHistoryService` — actor for thread-safe execution history persistence

**Task identity:** Each task uses its launchd label as its primary identity. The `id: UUID` is deterministically derived from the label via `ScheduledTask.uuidFromLabel()`. New tasks get a `com.user.<sanitized-name>` label by default.

**Process execution:** `ShellExecutor` actor wraps Foundation `Process`. Handles executables, shell scripts, and AppleScript. Auto-chmod 755 for non-executable files. Supports timeouts (default 60s).

**UI structure:** `MainView` uses `NavigationSplitView` (three-column: sidebar/content/detail). Sidebar uses `List(selection:)` with `.tag()` — not `NavigationLink` (this was an intentional fix; `NavigationLink` fights with manual content switching).

## Key Gotchas

- **Discovered plist tasks** store the shell binary (e.g. `/bin/bash`) as the `ProgramArguments[0]` path, with the actual script as subsequent arguments. `LaunchdService.runNow` detects this to avoid double-wrapping (`/bin/bash /bin/bash ...`).
- **Table sorting**: `TaskListViewModel.filteredTasks` must not apply its own sort — the SwiftUI `Table` manages sort order via `sortOrder` binding. Adding a hardcoded `.sorted()` will silently override table column sorting.
- **App sandbox is disabled** (entitlements) because the app needs direct access to `~/Library/LaunchAgents/`, crontab, and arbitrary script execution.
- **Read-only tasks**: Tasks from `/Library/LaunchAgents/` and `/Library/LaunchDaemons/` are marked `isReadOnly` — edit/delete buttons are disabled.
- **Update flow for launchd**: `LaunchdService.updateTask(oldTask:newTask:)` does: unload old → delete old plist → write new plist → load new. This handles label/filename changes.
- The Xcode scheme is shared (checked into `xcshareddata/xcschemes/`) for CI builds.

## CI/CD

GitHub Actions (`.github/workflows/release.yml`) runs on every push to `main`: builds a Release archive, creates a ZIP of the .app, and publishes a GitHub Release with a version tag (`v{MARKETING_VERSION}-{SHORT_SHA}`).

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set in `project.pbxproj` (both Debug and Release configurations). Update both when bumping versions.

**Bump semver** (`MARKETING_VERSION` in pbxproj) when making changes:
- **Patch** (1.1.0 → 1.1.1): bug fixes, UI tweaks, tooltip changes
- **Minor** (1.1.0 → 1.2.0): new features, new filters, new views
- **Major** (1.x → 2.0.0): breaking changes to data format or architecture
