// Self-check for non-UI logic (no test target in this project).
// Run: scripts/selfcheck/run.sh

import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); exit(1) }
    print("ok: \(msg)")
}

// ShellWords — cron command / editor argument parsing
check(ShellWords.split("'/path/my bin' -a 'it'\\''s'") == ["/path/my bin", "-a", "it's"], "single quotes + escaped quote")
check(ShellWords.split("a \"b \\\"c\\\" $d\" e\\ f") == ["a", "b \"c\" $d", "e f"], "double quotes + backslash")
check(ShellWords.split("  x   y ") == ["x", "y"], "whitespace")
let tricky = ["plain", "with space", "it's", "", "$HOME", "a\"b"]
check(ShellWords.split(ShellWords.join(tricky)) == tricky, "join/split round trip")

// Script ProgramArguments: keep interpreter + arguments for both editor- and plist-shaped actions
var zsh = TaskAction(type: .shellScript, path: "/bin/zsh", arguments: ["/x/run.sh", "--flag"])
check(PlistGenerator.programArguments(for: zsh) == ["/bin/zsh", "/x/run.sh", "--flag"], "parsed zsh task keeps interpreter")
zsh = TaskAction(type: .shellScript, path: "/x/run.sh", arguments: ["a b"])
check(PlistGenerator.programArguments(for: zsh) == ["/bin/bash", "/x/run.sh", "a b"], "editor script task keeps arguments")
zsh = TaskAction(type: .shellScript, path: "/usr/bin/ssh", arguments: [])
check(PlistGenerator.programArguments(for: zsh) == ["/bin/bash", "/usr/bin/ssh"], "ssh is not a shell")

// Plist merge keeps unmodelled keys, multi-calendar entries and KeepAlive conditions
let tmpPlist = NSTemporaryDirectory() + "selfcheck-\(UUID().uuidString).plist"
let original: [String: Any] = [
    "Label": "com.user.selfcheck", "ProgramArguments": ["/bin/zsh", "/x/run.sh"],
    "StartCalendarInterval": [["Hour": 3], ["Hour": 15]],
    "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30, "WatchPaths": ["/tmp/w"],
]
try! PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: URL(fileURLWithPath: tmpPlist))
var edited = LaunchdService.shared.parsePlistData(FileManager.default.contents(atPath: tmpPlist)!)!
edited.name = "Renamed"
let merged = try! PropertyListSerialization.propertyList(
    from: Data(LaunchdService.shared.plistContent(for: edited, mergingWith: tmpPlist).utf8), format: nil) as! [String: Any]
try? FileManager.default.removeItem(atPath: tmpPlist)
check(merged["ThrottleInterval"] as? Int == 30 && merged["WatchPaths"] as? [String] == ["/tmp/w"], "unmodelled keys preserved")
check((merged["StartCalendarInterval"] as? [[String: Int]])?.count == 2, "multiple calendar entries preserved")
check(merged["KeepAlive"] is [String: Any], "KeepAlive conditions preserved")
check(merged["ProgramArguments"] as? [String] == ["/bin/zsh", "/x/run.sh"], "interpreter preserved")
check(merged["MacSchedulerName"] as? String == "Renamed", "edit applied")
edited.trigger = TaskTrigger(type: .interval, intervalSeconds: 60)
edited.keepAlive = false
let changed = try! PropertyListSerialization.propertyList(
    from: Data(LaunchdService.shared.plistContent(for: edited, mergingWith: nil).utf8), format: nil) as! [String: Any]
check(changed["StartCalendarInterval"] == nil && changed["KeepAlive"] == nil && changed["StartInterval"] as? Int == 60,
      "changed managed keys replace old ones")

// launchd update: every old→new location combination needs at most one admin prompt.
// Step kinds mirror LaunchdService.updateTask: write new, bootout old, rm old (if moved), load new.
let locations: [TaskLocation] = [.userAgent, .systemAgent, .systemDaemon]
for old in locations {
    for new in locations {
        var kinds: [Bool?] = [new.requiresElevation, old == .systemDaemon ? true : nil]
        if old != new { kinds.append(old.requiresElevation ? true : nil) }
        kinds.append(new == .systemDaemon)
        let root = LaunchdService.resolveRoot(kinds)
        let prompts = zip(root, [false] + root).filter { $0 && !$1 }.count
        check(prompts <= 1 && (prompts == 1) == (old.requiresElevation || new.requiresElevation),
              "\(old.rawValue) → \(new.rawValue): \(prompts) admin prompt(s)")
    }
}

// Docker port formats compare equal across discovery/editor
check(DockerService.publishedPorts(["80/tcp -> 0.0.0.0:8080", "80/tcp -> :::8080", "443/tcp"])
      == DockerService.publishedPorts(["8080:80/tcp"]), "discovery vs editor ports")
check(DockerService.publishedPorts(["8080:80"]) != DockerService.publishedPorts(["9090:80/tcp"]), "port change detected")

// ShellExecutor
let sem = DispatchSemaphore(value: 0)
Task {
    let sh = ShellExecutor.shared

    var start = Date()
    let slow = try await sh.execute(command: "/bin/sleep", arguments: ["10"], timeout: 1)
    check(Date().timeIntervalSince(start) < 4 && slow.exitCode != 0, "timeout kills hung process")

    start = Date()
    let bg = try await sh.execute(command: "/bin/sh", arguments: ["-c", "sleep 30 & echo hi"], timeout: 5)
    check(Date().timeIntervalSince(start) < 3 && bg.standardOutput == "hi", "backgrounded child doesn't block return")

    let big = try await sh.execute(command: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' a"])
    check(big.standardOutput.hasSuffix("truncated at 1024KB ...]"), "output capped at 1MB")

    let ok = try await sh.execute(command: "/bin/echo", arguments: ["hello"])
    check(ok.exitCode == 0 && ok.standardOutput == "hello", "normal command")

    do {
        _ = try await sh.execute(command: "/nonexistent/bin")
        check(false, "missing binary throws")
    } catch {
        check(true, "missing binary throws")
    }
    sem.signal()
}
sem.wait()
print("all checks passed")
