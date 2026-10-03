// Self-check for non-UI logic (no test target in this project).
// Run: scripts/selfcheck/run.sh

import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); exit(1) }
    print("ok: \(msg)")
}

// shellSplit — cron command parsing
check(CronService.shellSplit("'/path/my bin' -a 'it'\\''s'") == ["/path/my bin", "-a", "it's"], "single quotes + escaped quote")
check(CronService.shellSplit("a \"b \\\"c\\\" $d\" e\\ f") == ["a", "b \"c\" $d", "e f"], "double quotes + backslash")
check(CronService.shellSplit("  x   y ") == ["x", "y"], "whitespace")

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
