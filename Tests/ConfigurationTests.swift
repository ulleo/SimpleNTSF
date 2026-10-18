import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func waitUntil(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), message)
}

@main
struct ConfigurationTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let home = fm.homeDirectoryForCurrentUser
        let target = home.appendingPathComponent("Mounted/Configuration Test").path
        try "\(uuid):\(target)\n".write(to: config, atomically: true, encoding: .utf8)
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.volumeName = "Test Volume"
            result.device = "disk99s1"
            result.currentMount = target
            result.isMounted = true
            result.usage = "1 GB / 2 GB"
            result.fileSystemType = "NTFS"
            result.isTimeout = true
            return result
        })
        var loaded = false
        manager.loadConfig { loaded = true }
        waitUntil("initial configuration must load") { loaded }
        let before = manager.disks[0]
        let saved = manager.updateMountPoint(uuid: uuid, newMountPoint: "~/Mounted/../Mounted/New Target")
        expect(saved.success, "valid target change must save")
        var expected = before
        expected.mountPoint = home.appendingPathComponent("Mounted/New Target").path
        expect(manager.disks == [expected], "save must publish normalized target and preserve all volume information")
        loaded = false
        manager.loadConfig { loaded = true }
        waitUntil("saved configuration must reload") { loaded }
        expect(manager.disks == [expected], "reloading must show the same saved configuration")
        print("PASS: edited target normalization and volume metadata survive reload")
        let secondUUID = "22345678-1234-1234-1234-123456789ABC"
        let added = manager.addDisk(uuid: secondUUID, mountPoint: "~/Mounted/Second")
        expect(added.success, "valid new mount configuration must save")
        expect(manager.disks.last?.uuid == secondUUID && manager.disks.last?.mountPoint == home.appendingPathComponent("Mounted/Second").path, "adding configuration must publish its normalized target without view orchestration")
        waitUntil("added volume query must finish") { !manager.isLoading }
        let published = manager.disks
        let invalidData = Data([0xff, 0xfe])
        try invalidData.write(to: config)
        let failedAdd = manager.addDisk(uuid: "32345678-1234-1234-1234-123456789ABC", mountPoint: "~/Mounted/Third")
        expect(!failedAdd.success, "unreadable configuration must reject adding a volume")
        expect(manager.disks == published, "read failure must retain published configuration")
        let retainedData = try Data(contentsOf: config)
        expect(retainedData == invalidData, "read failure must not overwrite the existing file")
        print("PASS: adding publishes configuration, read failure never overwrites it")
        expect(!manager.validateMountPoint(home.path + "-other/Target").valid, "a sibling with the same name prefix is not inside the user directory")
        let fixture = home.appendingPathComponent(".simplentfs-test-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let escape = fixture.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: directory)
        expect(!manager.validateMountPoint(escape.appendingPathComponent("Target").path).valid, "symlink targets outside home must be rejected")
        let file = fixture.appendingPathComponent("file")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        expect(!manager.validateMountPoint(file.path).valid, "existing files cannot be mount points")
        expect(!manager.validateMountPoint(file.appendingPathComponent("Target").path).valid, "non-directory ancestors cannot contain mount points")
        expect(!manager.validateMountPoint("~/Mounted/one\ntwo").valid, "line breaks cannot corrupt the configuration format")
        let real = fixture.appendingPathComponent("Real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = fixture.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        try "\(uuid):\(target)\n".write(to: config, atomically: true, encoding: .utf8)
        expect(manager.updateMountPoint(uuid: uuid, newMountPoint: alias.appendingPathComponent("New").path).success, "symlinks inside home may be used")
        expect(manager.disks.first?.mountPoint == real.appendingPathComponent("New").path, "published target must resolve symlinks consistently")
        print("PASS: directory ownership, symlink resolution and non-directory rejection")
        expect(manager.updateMountPoint(uuid: uuid, newMountPoint: "~/Mounted/./Configuration Test").success, "equivalent target must save")
        expect(!manager.disks[0].needsRemount, "equivalent target and actual paths must not request remount")
        let snapshot = manager.disks
        let contents = try Data(contentsOf: config)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let writeFailure = manager.updateMountPoint(uuid: uuid, newMountPoint: "~/Mounted/Write Failure")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        expect(!writeFailure.success && !writeFailure.message.isEmpty, "failed write must be reported")
        expect(manager.disks == snapshot, "failed write must retain all published volume information")
        let contentsAfterFailure = try Data(contentsOf: config)
        expect(contentsAfterFailure == contents, "failed write must retain persisted configuration")
        print("PASS: equivalent target avoids remount, failed write preserves configuration and state")
    }
}
