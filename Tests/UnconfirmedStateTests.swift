import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func refresh(_ manager: DiskManager) {
    var completed = false
    manager.loadConfig { completed = true }
    let deadline = Date().addingTimeInterval(3)
    while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(completed, "refresh must complete even when a volume query fails")
}

@main
struct UnconfirmedStateTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Test").path
        try "\(uuid):\(target)\n".write(to: config, atomically: true, encoding: .utf8)
        let manager = DiskManager(configURL: config, queryDisk: { _ in throw VolumeQueryFailure.failed("设备查询失败") })
        refresh(manager)
        let disk = manager.disks[0]
        expect(!disk.isStateConfirmed && !disk.hasConfirmedInformation, "first query failure must not invent confirmed history")
        expect(disk.statusMessage == "状态未确认", "failed query must not claim mounted or unmounted")
        expect(!disk.canMount && !disk.canUnmount && !disk.needsRemount, "unknown volume must disable every disk operation")
        expect(disk.device.isEmpty && disk.currentMount.isEmpty && disk.usage == nil, "first failure must not fabricate device or mount information")
        let mount = manager.mountDisk(uuid: uuid, mountPoint: target)
        let unmount = manager.unmountDisk(uuid: uuid, mountPoint: target)
        expect(!mount.success && mount.message.contains("状态未确认"), "mount execution must reject unknown state before running commands")
        expect(!unmount.success && unmount.message.contains("状态未确认"), "unmount and the first step of remount must reject unknown state")
        var backgroundRejected = false
        DispatchQueue.global().async {
            let result = manager.mountDisk(uuid: uuid, mountPoint: target)
            DispatchQueue.main.async { backgroundRejected = !result.success && result.message.contains("状态未确认") }
        }
        let deadline = Date().addingTimeInterval(3)
        while !backgroundRejected && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(backgroundRejected, "background batch execution must obey the same confirmed-state gate")
        print("PASS: first query failure has no history and blocks all disk operations")
        let secondUUID = "22345678-1234-1234-1234-123456789ABC"
        try "\(uuid):\(target)\n\(secondUUID):\(target) second\n".write(to: config, atomically: true, encoding: .utf8)
        var phase = 0
        let recovering = DiskManager(configURL: config, queryDisk: { disk in
            if phase == 1 && disk.uuid == uuid { throw VolumeQueryFailure.timedOut }
            var result = disk
            result.device = "disk99s1"
            result.volumeName = "Retained Volume"
            result.fileSystemType = "NTFS"
            result.usage = phase == 2 ? nil : "1 GB / 2 GB"
            result.isMounted = phase != 2
            result.currentMount = phase == 2 ? "" : "/Volumes/Actual"
            return result
        })
        refresh(recovering)
        let confirmed = recovering.disks[0]
        expect(confirmed.isStateConfirmed && confirmed.canUnmount && confirmed.needsRemount, "confirmed mounted volume must permit applicable actions")
        phase = 1
        refresh(recovering)
        let unknown = recovering.disks[0]
        expect(!unknown.isStateConfirmed && unknown.hasConfirmedInformation && unknown.isTimeout, "timeout must label retained information as unconfirmed")
        expect(unknown.volumeName == confirmed.volumeName && unknown.device == confirmed.device && unknown.currentMount == confirmed.currentMount && unknown.fileSystemType == confirmed.fileSystemType && unknown.usage == confirmed.usage, "failed query must retain last confirmed volume details for reference")
        expect(unknown.queryFailureMessage == "查询超时，请刷新重试", "failure cause must be visible alongside status")
        expect(recovering.disks[1].isStateConfirmed, "one volume failure must not invalidate another successful query")
        expect(!recovering.mountDisk(uuid: uuid, mountPoint: target).success && !recovering.unmountDisk(uuid: uuid, mountPoint: target).success, "retained history cannot authorize disk operations")
        phase = 2
        refresh(recovering)
        let retried = recovering.disks[0]
        expect(retried.isStateConfirmed && retried.canMount && !retried.canUnmount && !retried.needsRemount, "successful retry must restore operations appropriate for the newly confirmed unmounted state")
        expect(!retried.isTimeout && retried.queryFailureMessage == nil && retried.currentMount.isEmpty && retried.usage == nil, "successful retry must replace history and clear the failure")
        print("PASS: timeout retains reference information, isolates failures and refresh restores operations")
    }
}
