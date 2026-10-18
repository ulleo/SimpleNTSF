import Foundation

@main
struct PermissionsTests {
    static func main() throws {
        let oldConfiguration = "alice ALL=(ALL) NOPASSWD: NOEXEC: /opt/homebrew/sbin/mount_ntfs, /usr/sbin/diskutil"
        guard case .incomplete(let oldMissing) = PermissionConfiguration.status(content: oldConfiguration, username: "alice") else { fatalError("旧配置不能误报完整权限") }
        precondition(oldMissing.contains("/sbin/mount"), "旧 NTFS 权限配置应明确缺少系统挂载授权")
        let complete = "alice ALL=(ALL) NOPASSWD: EXEC: /opt/homebrew/sbin/mount_ntfs, /sbin/mount, /usr/sbin/diskutil"
        precondition(PermissionConfiguration.status(content: complete, username: "alice") == .configured, "完整权限配置应被识别")
        let suffix = "alice ALL=(ALL) NOPASSWD: EXEC: /opt/homebrew/sbin/mount_ntfs, /sbin/mount_extra, /usr/sbin/diskutil # /sbin/mount"
        precondition(PermissionConfiguration.status(content: suffix, username: "alice") == .incomplete(missingCommands: ["/sbin/mount"]), "注释或命令前缀不能充当授权项")
        precondition(PermissionConfiguration.status(content: complete.replacingOccurrences(of: "alice", with: "mallory"), username: "alice") != .configured, "其他用户的权限不能作为当前用户授权")
        precondition(PermissionConfiguration.status(content: complete.replacingOccurrences(of: "EXEC:", with: "NOEXEC:"), username: "alice") != .configured, "NOEXEC不能充当需要执行挂载helper的权限")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("sudoers-sample")
        precondition(PermissionConfiguration.status(fileURL: config, username: "alice") == .missing, "配置不存在应明确显示尚未配置")
        try complete.write(to: config, atomically: true, encoding: .utf8)
        precondition(PermissionConfiguration.status(fileURL: config, username: "alice") == .configured, "配置文件与样例内容必须给出相同结果")
        try Data([0xff]).write(to: config)
        precondition(PermissionConfiguration.status(fileURL: config, username: "alice") == .unreadable, "不可读取的配置不能显示为已配置")
        precondition(PermissionConfiguration.Status.missing.message == "尚未配置免密码权限", "未配置提示应明确")
        precondition(PermissionConfiguration.Status.unreadable.message == "无法读取权限配置，请重新配置", "读取失败提示应明确")
        precondition(PermissionConfiguration.status(content: oldConfiguration, username: "alice").message.contains("/sbin/mount"), "旧权限配置应在界面指出缺项")
        let generated = try PermissionConfiguration.generatedContent(username: "john-doe")
        precondition(PermissionConfiguration.status(content: generated, username: "john-doe") == .configured, "生成及校验必须使用相同的真实用户和能力规则")
        let deny = complete + "\nalice ALL=(ALL) NOPASSWD: EXEC: !/sbin/mount"
        precondition(PermissionConfiguration.status(content: deny, username: "alice") != .configured, "后续否定规则必须覆盖先前授权")
        let password = complete + "\nalice ALL=(ALL) PASSWD: /sbin/mount"
        precondition(PermissionConfiguration.status(content: password, username: "alice") != .configured, "PASSWD覆写不能误报免密码")
        let restricted = complete + "\nalice ALL=(ALL) NOPASSWD: /sbin/mount -t apfs"
        precondition(PermissionConfiguration.status(content: restricted, username: "alice") != .configured, "限制参数的项不能充当所有文件系统授权")
        let inherited = "alice ALL=(ALL) NOPASSWD: EXEC: /opt/homebrew/sbin/mount_ntfs, PASSWD: /sbin/mount, /usr/sbin/diskutil"
        precondition(PermissionConfiguration.status(content: inherited, username: "alice") == .incomplete(missingCommands: ["/sbin/mount", "/usr/sbin/diskutil"]), "密码标签应继承到同一规则后续命令")
        let restored = complete + "\nalice ALL=(ALL) NOPASSWD: NOEXEC: /sbin/mount, EXEC: /sbin/mount"
        precondition(PermissionConfiguration.status(content: restored, username: "alice") == .configured, "明确EXEC可恢复helper权限")
        for unsupported in ["Defaults noexec", "#include /etc/other", "alice ALL=(ALL) NOPASSWD: !ALL", "%staff ALL=(ALL) NOPASSWD: /sbin/mount", "ALL ALL=(ALL) PASSWD: /sbin/mount"] {
            precondition(PermissionConfiguration.status(content: complete + "\n" + unsupported, username: "alice") == .unsupported, "超出支持子集的规则不能宣称核实完整")
        }
        print("PermissionsTests passed")
    }
}
