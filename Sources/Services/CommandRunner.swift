import Foundation
import Darwin

enum CommandOutcome: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case launchFailed(String)
    case timedOut
    case outputIncomplete
    case ioFailed(String)
    case outputLimitExceeded
}

struct CommandResult {
    let outcome: CommandOutcome
    var stdout: Data = Data()
    var stderr: Data = Data()
    var processExited: Bool = true
    var outputComplete: Bool = true

    var success: Bool { outcome == .exited(0) && processExited && outputComplete }
    var message: String {
        let details = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .exited(let code): return details.isEmpty ? "命令退出码：\(code)" : details
        case .signaled(let signal): return "命令被信号终止：\(signal)" + (details.isEmpty ? "" : "；" + details)
        case .launchFailed(let error): return "命令启动失败：" + error
        case .timedOut: return processExited ? "命令执行超时" : "命令执行超时，进程退出尚未确认"
        case .outputIncomplete: return "命令输出未完整结束"
        case .ioFailed(let error): return "命令输出读取失败：" + error
        case .outputLimitExceeded: return "命令输出超过大小限制"
        }
    }
}

typealias CommandExecuting = (String, [String], TimeInterval) -> CommandResult

/// Synchronous execution for background work. Parsing and command-specific policies belong to callers.
struct CommandRunner {
    let outputLimit: Int

    init(outputLimit: Int = 8 * 1024 * 1024) {
        self.outputLimit = max(0, outputLimit)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        defer {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return CommandResult(outcome: .launchFailed(error.localizedDescription)) }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = error.fileHandleForReading.fileDescriptor
        let pid = process.processIdentifier
        // Foundation creates an isolated group on supported macOS versions, but verify before signaling it.
        let isolatedGroup = getpgid(pid) == pid && pid != getpgrp()
        var failure: CommandOutcome?
        for fd in [outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            if flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
                failure = .ioFailed(String(cString: strerror(errno)))
            }
        }
        var stdout = Data(), stderr = Data()
        var outputEOF = false, errorEOF = false
        var terminationStarted: TimeInterval?
        var exitedAt: TimeInterval?
        var killSent = false
        while true {
            // If nonblocking setup failed, do not risk a blocking read.
            if case .ioFailed = failure {} else {
                if let error = drain(outputFD, into: &stdout, eof: &outputEOF) { failure = failure ?? error }
                if let error = drain(errorFD, into: &stderr, eof: &errorEOF) { failure = failure ?? error }
            }
            let now = ProcessInfo.processInfo.systemUptime
            let running = process.isRunning
            if !running && exitedAt == nil { exitedAt = now }
            if !running && outputEOF && errorEOF { break }
            if failure == nil, let exitedAt = exitedAt, now - exitedAt >= 0.15 {
                failure = .outputIncomplete
            }
            if failure == nil && now - started >= max(0, timeout) { failure = .timedOut }
            if failure != nil && terminationStarted == nil {
                terminationStarted = now
                if isolatedGroup || running { _ = kill(isolatedGroup ? -pid : pid, SIGTERM) }
            }
            if let terminationStarted = terminationStarted {
                if now - terminationStarted >= 0.15 && !killSent {
                    if isolatedGroup || running { _ = kill(isolatedGroup ? -pid : pid, SIGKILL) }
                    killSent = true
                }
                // No unbounded waitUntilExit/readToEnd even when termination cannot be confirmed.
                if now - terminationStarted >= 0.65 { break }
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let exited = !process.isRunning
        let outcome = failure ?? (process.terminationReason == .exit
            ? CommandOutcome.exited(process.terminationStatus) : .signaled(process.terminationStatus))
        return CommandResult(outcome: outcome, stdout: stdout, stderr: stderr,
                             processExited: exited, outputComplete: outputEOF && errorEOF && failure != .outputIncomplete && failure != .outputLimitExceeded)
    }

    private func drain(_ fd: Int32, into data: inout Data, eof: inout Bool) -> CommandOutcome? {
        guard !eof else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var limitExceeded = false
        // Yield between streams and deadline checks even when a child writes continuously.
        for _ in 0..<8 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let retainedCount = min(count, max(0, outputLimit - data.count))
                data.append(contentsOf: buffer.prefix(retainedCount))
                if retainedCount < count { limitExceeded = true }
            }
            else if count == 0 { eof = true; break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { return .ioFailed(String(cString: strerror(errno))) }
        }
        return limitExceeded ? .outputLimitExceeded : nil
    }
}
