import Foundation

@main
struct PermissionsTests {
    static func main() throws {
        let oldConfiguration = "alice ALL=(ALL) NOPASSWD: NOEXEC: /opt/homebrew/sbin/mount_ntfs, /usr/sbin/diskutil"
        precondition(PermissionConfiguration.status(content: oldConfiguration) == .incomplete(missingCommands: ["/sbin/mount"]), "旧 NTFS 权限配置应明确缺少系统挂载授权")
        let complete = "alice ALL=(ALL) NOPASSWD: NOEXEC: /opt/homebrew/sbin/mount_ntfs, /sbin/mount, /usr/sbin/diskutil"
        precondition(PermissionConfiguration.status(content: complete) == .configured, "完整权限配置应被识别")
        let suffix = "alice ALL=(ALL) NOPASSWD: NOEXEC: /opt/homebrew/sbin/mount_ntfs, /sbin/mount_extra, /usr/sbin/diskutil # /sbin/mount"
        precondition(PermissionConfiguration.status(content: suffix) == .incomplete(missingCommands: ["/sbin/mount"]), "注释或命令前缀不能充当授权项")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("sudoers-sample")
        precondition(PermissionConfiguration.status(fileURL: config) == .missing, "配置不存在应明确显示尚未配置")
        try complete.write(to: config, atomically: true, encoding: .utf8)
        precondition(PermissionConfiguration.status(fileURL: config) == .configured, "配置文件与样例内容必须给出相同结果")
        try Data([0xff]).write(to: config)
        precondition(PermissionConfiguration.status(fileURL: config) == .unreadable, "不可读取的配置不能显示为已配置")
        precondition(PermissionConfiguration.Status.missing.message == "尚未配置免密码权限", "未配置提示应明确")
        precondition(PermissionConfiguration.Status.unreadable.message == "无法读取权限配置，请重新配置", "读取失败提示应明确")
        precondition(PermissionConfiguration.status(content: oldConfiguration).message == "权限配置缺少：/sbin/mount", "旧权限配置应在界面指出缺项")
        print("PermissionsTests passed")
    }
}
