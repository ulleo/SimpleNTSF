import Foundation

@main
struct PermissionSetupTests {
    static func main() throws {
        let complete = "alice ALL=(ALL) NOPASSWD: NOEXEC: /opt/homebrew/sbin/mount_ntfs, /sbin/mount, /usr/sbin/diskutil"
        var authorizationScript = ""
        let gate = DispatchSemaphore(value: 0)
        let setup = PermissionSetup(username: "alice", execute: { executable, arguments, timeout in
            precondition(executable == "/usr/bin/osascript")
            authorizationScript = arguments[1]
            precondition(timeout >= 120, "管理员交互不能使用短查询时限")
            gate.wait()
            return CommandResult(outcome: .exited(0), stdout: Data(complete.utf8))
        }, readStatus: { .missing })
        var result: PermissionSetup.Result?
        setup.configure { result = $0 }
        precondition(setup.isConfiguring && result == nil, "等待授权时必须保持忙碌")
        gate.signal()
        wait { result != nil }
        precondition(result == .configured && !setup.isConfiguring && setup.status == .configured,
                     "安装后核实完整配置才可完成成功")
        let cancelled = PermissionSetup(username: "alice", execute: { _, _, _ in
            CommandResult(outcome: .exited(0), stdout: Data("SIMPLENTFS_AUTH_CANCELLED".utf8))
        }, readStatus: { .configured })
        var cancellation: PermissionSetup.Result?
        cancelled.configure { cancellation = $0 }
        wait { cancellation != nil }
        precondition(cancellation == .cancelled && !cancelled.isConfiguring,
                     "取消授权必须明确结束，旧配置存在也不能报本次成功")
        let timeout = PermissionSetup(username: "alice", execute: { _, _, _ in
            CommandResult(outcome: .timedOut, processExited: false, outputComplete: false)
        }, readStatus: { .configured })
        var timeoutResult: PermissionSetup.Result?
        timeout.configure { timeoutResult = $0 }
        wait { timeoutResult != nil }
        guard case .unconfirmed = timeoutResult else { fatalError("超时不能宣称安装没有发生") }
        precondition(!timeout.isConfiguring && timeout.status == .configured)
        let invalidUser = PermissionSetup(username: "alice ALL=(ALL)", execute: { _, _, _ in
            fatalError("不支持的用户名必须在请求授权前拒绝")
        }, readStatus: { .missing })
        var invalidResult: PermissionSetup.Result?
        invalidUser.configure { invalidResult = $0 }
        wait { invalidResult != nil }
        guard case .failed = invalidResult else { fatalError("用户名不能被静默修改") }
        precondition(!invalidUser.isConfiguring)
        let cases: [(CommandResult, String)] = [
            (CommandResult(outcome: .launchFailed("missing executable")), "启动失败"),
            (CommandResult(outcome: .exited(1), stderr: Data("installation denied".utf8)), "installation denied"),
            (CommandResult(outcome: .exited(0), stdout: Data("alice ALL=(ALL) NOPASSWD: /opt/homebrew/sbin/mount_ntfs".utf8)), "缺少"),
            (CommandResult(outcome: .exited(0)), "缺少")
        ]
        for (command, diagnostic) in cases {
            let failed = PermissionSetup(username: "alice", execute: { _, _, _ in command }, readStatus: { .configured })
            var failure: PermissionSetup.Result?
            failed.configure { failure = $0 }
            wait { failure != nil }
            precondition(!failed.isConfiguring && failure?.success == false && failure!.message.contains(diagnostic),
                         "执行异常/不完整readback不能因旧配置存在而成功，且必须释放忙碌状态")
        }
        let hyphenated = try PermissionConfiguration.generatedContent(username: "john-doe")
        precondition(hyphenated.hasPrefix("john-doe ALL="),
                     "保留实际用户名，不能删掉连字符")
        // Compile, but never execute, the authorization script. This cannot request admin access.
        let compiled = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer { try? FileManager.default.removeItem(at: compiled) }
        let syntax = CommandRunner().run(executable: "/usr/bin/osacompile",
                                         arguments: ["-o", compiled.path, "-e", authorizationScript], timeout: 10)
        precondition(syntax.success, "授权脚本必须可编译：" + syntax.message)
        print("PermissionSetupTests passed")
    }

    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        precondition(condition(), "权限操作必须有界结束")
    }
}
