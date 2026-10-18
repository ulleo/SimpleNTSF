import Foundation
import Combine

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func waitUntil(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), message)
}

private final class ControlledQuery {
    private let lock = NSLock()
    private var pending: [(DiskInfo, DispatchSemaphore)] = []
    var requests: [DiskInfo] {
        lock.lock(); defer { lock.unlock() }
        return pending.map { $0.0 }
    }
    func query(_ disk: DiskInfo) -> DiskInfo {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); pending.append((disk, gate)); lock.unlock()
        expect(gate.wait(timeout: .now() + 4) == .success, "test must release the volume query")
        var result = disk
        result.volumeName = "Confirmed Volume"
        result.device = "disk99s1"
        result.currentMount = "/Volumes/Actual Location"
        result.isMounted = true
        result.fileSystemType = "NTFS"
        // Query results must not be allowed to redefine the configured target.
        result.mountPoint = "/Volumes/Not A Configured Target"
        return result
    }
    func release(_ index: Int) {
        lock.lock(); let gate = pending[index].1; lock.unlock()
        gate.signal()
    }
}

@main
struct RefreshRaceTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let home = fm.homeDirectoryForCurrentUser
        let oldTarget = home.appendingPathComponent("Mounted/Old").path
        let newTarget = home.appendingPathComponent("Mounted/New").path
        try "\(uuid):\(oldTarget)\n".write(to: config, atomically: true, encoding: .utf8)
        let query = ControlledQuery()
        let manager = DiskManager(configURL: config, queryDisk: query.query)
        var completed = 0
        var publications: [[DiskInfo]] = []
        let observation = manager.$disks.sink { publications.append($0) }
        defer { observation.cancel() }
        manager.loadConfig { completed += 1 }
        waitUntil("old query must begin") { query.requests.count == 1 }
        expect(manager.updateMountPoint(uuid: uuid, newMountPoint: newTarget).success, "target edit must save during a pending query")
        manager.loadConfig { completed += 1 }
        query.release(0)
        waitUntil("configuration edit must trigger a fresh query") { query.requests.count == 2 }
        expect(manager.isLoading && completed == 0, "old result must not release either refresh waiter")
        expect(publications.flatMap { $0 }.allSatisfy { $0.mountPoint != oldTarget }, "obsolete target must never be republished")
        query.release(1)
        waitUntil("both requests must complete against the latest configuration") { completed == 2 }
        expect(!manager.isLoading, "latest publication must finish loading")
        expect(manager.disks.first?.mountPoint == newTarget, "latest configured target must survive stale query")
        expect(manager.disks.first?.currentMount == "/Volumes/Actual Location", "actual mount must remain separate from configured target")
        print("PASS: editing during refresh rejects old results and completes all waiters with the latest configuration")
        manager.loadConfig { completed += 1 }
        waitUntil("query before deletion must begin") { query.requests.count == 3 }
        expect(manager.deleteDisk(uuid: uuid), "deleting a volume during its query must succeed")
        let publicationAfterDeletion = publications.count
        expect(manager.disks.isEmpty, "deletion must immediately remove the visible volume")
        query.release(2)
        waitUntil("deleted configuration must finish refresh") { completed == 3 }
        expect(manager.disks.isEmpty, "old query must not restore the deleted volume")
        expect(publications.dropFirst(publicationAfterDeletion).allSatisfy { $0.isEmpty }, "deleted volume must never briefly reappear")
        print("PASS: deleting during refresh never republishes the removed volume")
        expect(manager.addDisk(uuid: uuid, mountPoint: newTarget).success, "first added configuration must save")
        waitUntil("query for first added volume must start") { query.requests.count == 4 }
        let secondUUID = "22345678-1234-1234-1234-123456789ABC"
        expect(manager.addDisk(uuid: secondUUID, mountPoint: "~/Mounted/Second").success, "second configuration must save during the first query")
        manager.loadConfig { completed += 1 }
        query.release(3)
        waitUntil("newly added configuration must receive its own query") { query.requests.count == 6 }
        expect(completed == 3 && manager.isLoading, "adding during a query must keep waiters pending until the latest configuration is queried")
        query.release(4)
        query.release(5)
        waitUntil("latest two-volume configuration must finish") { completed == 4 }
        expect(manager.addedUUIDs == Set([uuid, secondUUID]), "old query must not remove newly added configuration")
        expect(manager.disks.allSatisfy { $0.volumeName == "Confirmed Volume" }, "both added volumes must have queried information")
        print("PASS: adding during refresh publishes both queried configurations")
        let knownVolumes = manager.disks
        try Data([0xff, 0xfe]).write(to: config)
        manager.loadConfig { completed += 1 }
        waitUntil("failed refresh must release its waiter") { completed == 5 }
        expect(manager.refreshError != nil && manager.disks == knownVolumes, "read failure must preserve the latest known volumes and expose its error")
        try "\(uuid):\(newTarget)\n".write(to: config, atomically: true, encoding: .utf8)
        manager.loadConfig { completed += 1 }
        waitUntil("retry query must start") { query.requests.count == 7 }
        query.release(6)
        waitUntil("successful retry must finish") { completed == 6 }
        expect(manager.refreshError == nil && manager.disks.count == 1 && !manager.isLoading, "retry must clear the error and publish the recovered configuration")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(completed == 6, "every waiter must complete exactly once across invalidation and recovery")
        print("PASS: refresh recovers after read failure and completes every waiter exactly once")
    }
}
