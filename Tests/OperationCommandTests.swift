import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func waitUntil(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(predicate(), message)
}

// Synthetic schema example for compatibility with both the old field query and shared plist query.
private func metadata(arguments: [String], uuid: String, fileSystem: String) -> Data {
    if arguments.contains("-plist") {
        return try! PropertyListSerialization.data(fromPropertyList: [
            "DeviceIdentifier": "disk99s1", "VolumeUUID": uuid, "VolumeName": "Operation Test",
            "FilesystemType": fileSystem, "FilesystemName": fileSystem,
            "Internal": false, "Whole": false, "TotalSize": 1024
        ], format: .xml, options: 0)
    }
    return Data("Device Identifier: disk99s1\nFile System Personality: \(fileSystem)\n".utf8)
}

private func exercise(config: URL, uuid: String, target: URL, operation: VolumeOperation,
                      fileSystem: String = "NTFS", commandResults: [CommandResult],
                      mountedAfter: Bool, verificationFails: Bool = false)
    -> (result: VolumeOperationResult, calls: [[String]], deadlines: [TimeInterval], disk: DiskInfo) {
    var actualMounted = operation != .mount
    var calls: [[String]] = []
    var deadlines: [TimeInterval] = []
    let manager = DiskManager(configURL: config, queryDisk: { disk in
        if verificationFails && !calls.isEmpty { throw VolumeQueryFailure.timedOut }
        var result = disk
        result.device = "disk99s1"
        result.fileSystemType = fileSystem
        result.isMounted = actualMounted
        result.currentMount = actualMounted ? target.path : ""
        return result
    }, executeCommand: { executable, arguments, deadline in
        if executable == Constants.diskUtilPath {
            return CommandResult(outcome: .exited(0), stdout: metadata(arguments: arguments, uuid: uuid, fileSystem: fileSystem))
        }
        expect(executable == "/usr/bin/sudo", "disk operation must retain sudo execution")
        expect(calls.count < commandResults.count, "operation must not retry unexpectedly")
        let reply = commandResults[calls.count]
        calls.append(arguments)
        deadlines.append(deadline)
        actualMounted = calls.count == commandResults.count ? mountedAfter : false
        return reply
    })
    var loaded = false
    manager.loadConfig { loaded = true }
    waitUntil("operation fixture must load") { loaded }
    var result: VolumeOperationResult?
    manager.performOperation(uuid: uuid, operation: operation) { result = $0 }
    waitUntil("operation fixture must verify and finish") { result != nil }
    expect(manager.operatingUUIDs.isEmpty, "completed operation must release busy")
    return (result!, calls, deadlines, manager.disks[0])
}

@main
struct OperationCommandTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent(".simplentfs-operation-test-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory); try? fm.removeItem(at: target) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        try "\(uuid):\(target.path)\n".write(to: config, atomically: true, encoding: .utf8)
        var mounted = false
        var sudoCalls: [[String]] = []
        var deadlines: [TimeInterval] = []
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.device = "disk99s1"
            result.fileSystemType = "NTFS"
            result.isMounted = mounted
            result.currentMount = mounted ? target.path : ""
            return result
        }, executeCommand: { executable, arguments, timeout in
            if executable == Constants.diskUtilPath {
                return CommandResult(outcome: .exited(0), stdout: metadata(arguments: arguments, uuid: uuid, fileSystem: "NTFS"))
            }
            expect(executable == "/usr/bin/sudo", "operation must use its existing sudo mechanism")
            sudoCalls.append(arguments)
            deadlines.append(timeout)
            mounted = true
            return CommandResult(outcome: .timedOut)
        })
        var loaded = false
        manager.loadConfig { loaded = true }
        waitUntil("controlled initial refresh must finish") { loaded }
        var outcome: VolumeOperationResult?
        manager.performOperation(uuid: uuid, operation: .mount) { outcome = $0 }
        waitUntil("timed-out operation must verify actual state") { outcome != nil }
        expect(outcome?.commandOutcome == .timedOut, "operation must retain typed command timeout separately from state verification")
        expect(outcome?.commandSucceeded == false && manager.disks[0].isMounted && manager.disks[0].isStateConfirmed, "timeout must not be mistaken for an operation that did not happen")
        expect(sudoCalls == [["-n", Constants.mountNTFSPath, "/dev/disk99s1", target.path]] && deadlines == [15], "NTFS command, argument order and deadline must survive executor migration")
        print("PASS: bounded mount timeout retains exact arguments and verifies actual state")
        let failures: [(CommandResult, String)] = [
            (CommandResult(outcome: .launchFailed("missing executable")), "启动失败"),
            (CommandResult(outcome: .exited(7)), "7"),
            (CommandResult(outcome: .exited(1), stderr: Data("sudo: a password is required".utf8)), "a password is required"),
            (CommandResult(outcome: .exited(1), stderr: Data("filesystem damaged".utf8)), "filesystem damaged"),
            (CommandResult(outcome: .timedOut, stderr: Data("partial diagnostic".utf8)), "partial diagnostic")
        ]
        for (reply, diagnostic) in failures {
            let tested = exercise(config: config, uuid: uuid, target: target, operation: .mount,
                commandResults: [reply], mountedAfter: false)
            expect(tested.result.commandOutcome == reply.outcome && !tested.result.commandSucceeded, "typed launch, exit and timeout failures must survive the operation flow")
            expect(tested.result.commandMessage.contains(diagnostic), "command diagnostics must not be discarded")
            expect(tested.disk.isStateConfirmed && !tested.disk.isMounted, "even failed commands must query the actual volume state")
        }
        let uncertain = exercise(config: config, uuid: uuid, target: target, operation: .mount,
            commandResults: [CommandResult(outcome: .timedOut)], mountedAfter: true, verificationFails: true)
        expect(uncertain.result.commandOutcome == .timedOut && !uncertain.disk.isStateConfirmed, "failed timeout verification must remain unknown instead of asserting the mount never happened")
        print("PASS: launch, nonzero, sudo diagnostics and timeout failures preserve causes and verified state")
        let unmounted = exercise(config: config, uuid: uuid, target: target, operation: .unmount,
            commandResults: [CommandResult(outcome: .exited(0))], mountedAfter: false)
        expect(unmounted.calls == [["-n", Constants.diskUtilPath, "unmount", "/dev/disk99s1"]] && unmounted.deadlines == [10], "selected volume must use volume-scoped unmount without force")
        let remounted = exercise(config: config, uuid: uuid, target: target, operation: .remount,
            commandResults: [CommandResult(outcome: .exited(0)), CommandResult(outcome: .exited(5), stderr: Data("mount refused".utf8))], mountedAfter: false)
        expect(remounted.calls.count == 2 && remounted.result.commandOutcome == .exited(5) && !remounted.disk.isMounted, "partial remount failure must preserve failing step outcome and verify unmounted state without retry")
        print("PASS: volume-scoped unmount and partial remount use shared execution")
        let mappings: [(String, [String])] = [
            ("ExFAT", ["-t", "exfat"]), ("MS-DOS FAT32", ["-t", "msdos"]),
            ("Journaled HFS+", ["-t", "hfs"]), ("APFS", ["-t", "apfs"])
        ]
        for (fileSystem, flags) in mappings {
            let tested = exercise(config: config, uuid: uuid, target: target, operation: .mount, fileSystem: fileSystem,
                commandResults: [CommandResult(outcome: .exited(0))], mountedAfter: true)
            expect(tested.calls == [["-n", "/sbin/mount"] + flags + ["/dev/disk99s1", target.path]], "system mount mapping must match supported filesystem capabilities")
        }
        print("PASS: supported filesystem commands include explicit APFS and other required type flags")
    }
}
