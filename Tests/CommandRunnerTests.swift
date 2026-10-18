import Foundation
import Darwin

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct CommandRunnerTests {
    static func main() {
        if CommandLine.arguments.count > 1 {
            fixture(CommandLine.arguments[1])
            return
        }
        let runner = CommandRunner()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).path
        let result = runner.run(executable: executable, arguments: ["large-output"], timeout: 3)
        expect(result.outcome == .exited(0) && result.success, "large output on both streams must finish successfully")
        expect(result.stdout == Data(repeating: 111, count: 2_097_152), "stdout must be complete beyond pipe capacity")
        expect(result.stderr == Data(repeating: 101, count: 2_097_152), "stderr must be complete beyond pipe capacity")
        expect(result.processExited && result.outputComplete, "successful result must confirm child exit and complete capture")
        print("PASS: real process drains large stdout and stderr while running")
        let failed = runner.run(executable: executable, arguments: ["nonzero"], timeout: 1)
        expect(failed.outcome == .exited(7) && !failed.success, "nonzero exit must remain distinct from normal success")
        expect(String(decoding: failed.stderr, as: UTF8.self) == "fixture error", "nonzero exit must retain diagnostics")
        let launch = runner.run(executable: "/not/an/existing/executable", arguments: [], timeout: 1)
        if case .launchFailed = launch.outcome {} else { fatalError("missing executable must report launch failure") }
        let signaled = runner.run(executable: executable, arguments: ["signal"], timeout: 1)
        expect(signaled.outcome == .signaled(SIGTERM), "signal exit must remain distinct from a command's exit status")
        print("PASS: nonzero, launch failure and signal termination are distinct")
        let started = ProcessInfo.processInfo.systemUptime
        let timedOut = runner.run(executable: executable, arguments: ["ignore-term"], timeout: 0.1)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        expect(timedOut.outcome == .timedOut && !timedOut.success, "deadline must report timeout even if the child ignores TERM")
        expect(elapsed < 0.9, "timeout and escalation must bound the caller's wait")
        expect(timedOut.processExited, "timeout must observe the immediate child's exit after escalation")
        expect(String(decoding: timedOut.stdout, as: UTF8.self) == "ready", "timeout must retain captured output")
        print("PASS: TERM-resistant child is killed and its exit observed within a bounded timeout")
        for fixture in ["inherited-pipe", "detached-pipe"] {
            let started = ProcessInfo.processInfo.systemUptime
            let inherited = runner.run(executable: executable, arguments: [fixture], timeout: 3)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if let child = Int32(String(decoding: inherited.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                // The detached fixture escapes the original group; clean up only this known test child.
                if kill(child, 0) == 0 { kill(child, SIGKILL) }
            }
            expect(inherited.outcome == .outputIncomplete, "parent exit with inherited open pipes must report incomplete output")
            expect(elapsed < 1.4 && inherited.processExited, "inherited pipes must not hold the caller until descendant exit")
            if fixture == "detached-pipe" { expect(!inherited.outputComplete, "detached writer must be reported as incomplete capture") }
        }
        print("PASS: inherited and detached pipe writers cannot cause an unbounded drain")
        let bounded = CommandRunner(outputLimit: 32_768).run(executable: executable, arguments: ["large-output"], timeout: 3)
        expect(bounded.outcome == .outputLimitExceeded && !bounded.outputComplete, "oversized output must be reported rather than parsed as complete")
        expect(bounded.stdout.count <= 32_768 && bounded.stderr.count <= 32_768, "capture must have a bounded memory footprint")
        expect(bounded.processExited, "oversized output must not strand a running child")
        print("PASS: capture limit bounds memory and reports incomplete output")
    }

    private static func fixture(_ name: String) {
        switch name {
        case "inherited-pipe", "detached-pipe":
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).path
            var arguments = [strdup(executable), strdup(name == "detached-pipe" ? "detached-writer" : "pipe-writer"), nil]
            defer { arguments.forEach { free($0) } }
            var child: pid_t = 0
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            expect(posix_spawn(&child, executable, nil, nil, &arguments, &environment) == 0, "fixture child must start")
            FileHandle.standardOutput.write(Data("\(child)\n".utf8))
            usleep(50_000)
            _exit(0)
        case "pipe-writer", "detached-writer":
            if name == "detached-writer" { _ = setsid() }
            sleep(2)
        case "ignore-term":
            signal(SIGTERM, SIG_IGN)
            FileHandle.standardOutput.write(Data("ready".utf8))
            sleep(1)
        case "nonzero":
            FileHandle.standardError.write(Data("fixture error".utf8))
            _exit(7)
        case "signal":
            kill(getpid(), SIGTERM)
        case "large-output":
            let stdout = [UInt8](repeating: 111, count: 8192)
            let stderr = [UInt8](repeating: 101, count: 8192)
            for _ in 0..<256 {
                stdout.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
                stderr.withUnsafeBytes { _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            }
        default: fatalError("unknown fixture")
        }
    }
}
