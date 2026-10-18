import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), "controlled operation must finish")
}

@main
struct CapabilityTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent(".simplentfs-capability-test-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory); try? fm.removeItem(at: target) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        try "\(uuid):\(target.path)\n".write(to: config, atomically: true, encoding: .utf8)
        var commands: [[String]] = []
        var mode = 0
        var raw: [String: Any] = ["DeviceIdentifier": "disk99s1s2", "VolumeUUID": uuid,
            "VolumeName": "Synthetic APFS Volume", "FilesystemType": "apfs", "Internal": false]
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.device = "disk99s1s2"
            result.fileSystemType = "APFS"
            result.isMounted = false
            result.currentMount = ""
            return result
        }, executeCommand: { executable, arguments, _ in
            if executable == Constants.diskUtilPath {
                let bytes = try! PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
                return CommandResult(outcome: .exited(0), stdout: bytes)
            }
            expect(executable == "/usr/bin/sudo", "only controlled sudo adapter expected")
            commands.append(arguments)
            if mode == 0 { return CommandResult(outcome: .exited(1), stderr: Data("sudo: a password is required".utf8)) }
            if mode == 1 { return CommandResult(outcome: .exited(1), stderr: Data("filesystem damaged".utf8)) }
            return CommandResult(outcome: .exited(0))
        })
        var loaded = false
        manager.loadConfig { loaded = true }
        wait { loaded }
        func mount() -> VolumeOperationResult {
            var result: VolumeOperationResult?
            manager.performOperation(uuid: uuid, operation: .mount) { result = $0 }
            wait { result != nil }
            return result!
        }
        mode = 1
        let filesystemOnly = mount()
        expect(!filesystemOnly.authorizationDenied && manager.authorizationFailures.isEmpty, "an unrelated exit1 must not create an authorization warning")
        mode = 0
        let denied = mount()
        expect(denied.authorizationDenied && manager.authorizationFailures["/sbin/mount"] != nil, "recognized sudo denial must replace unconditional availability with runtime failure")
        expect(commands[0] == ["-n", "/sbin/mount", "-t", "apfs", "/dev/disk99s1s2", target.path], "valid nested volume device must use explicit APFS mapping")
        mode = 1
        let filesystemFailure = mount()
        expect(!filesystemFailure.authorizationDenied, "exit1 filesystem errors are not sudo authorization failures")
        mode = 2
        _ = mount()
        expect(manager.authorizationFailures.isEmpty, "successful execution of the same capability clears its runtime denial")
        let before = commands.count
        raw["APFSSnapshot"] = true
        let snapshot = mount()
        expect(!snapshot.commandSucceeded && snapshot.commandMessage.contains("快照") && commands.count == before, "snapshot preflight must refuse write mounting even with a valid multi-part device")
        raw.removeValue(forKey: "APFSSnapshot")
        raw["FilesystemType"] = "unknown_fs"
        let unknown = mount()
        expect(!unknown.commandSucceeded && unknown.commandMessage.contains("不支持") && commands.count == before, "unsupported filesystems must not fall through to a default mount command")
        raw["FilesystemType"] = "apfs"
        raw["DeviceIdentifier"] = "../../disk99s1"
        let invalid = mount()
        expect(!invalid.commandSucceeded && commands.count == before, "invalid device paths must never reach sudo")
        print("PASS: capability mapping, safe device preflight, snapshot refusal and runtime authorization feedback")
    }
}
