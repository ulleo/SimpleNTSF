import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func waitUntil(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(predicate(), message)
}
private func refresh(_ manager: DiskManager) {
    var done = false
    manager.loadConfig { done = true }
    waitUntil("refresh must finish") { done }
}

@main
struct BatchOperationTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuids = ["12345678-1234-1234-1234-123456789ABC", "22345678-1234-1234-1234-123456789ABC", "32345678-1234-1234-1234-123456789ABC"]
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Batch").path
        try uuids.map { "\($0):\(target)/\($0)\n" }.joined().write(to: config, atomically: true, encoding: .utf8)
        var commands: [String] = []
        var mounted: Set<String> = []
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            if disk.uuid == uuids[2] { throw VolumeQueryFailure.failed("disconnected") }
            var result = disk
            result.device = "disk99s1"
            result.volumeName = disk.uuid == uuids[0] ? "First" : "Second"
            result.isMounted = mounted.contains(disk.uuid)
            result.currentMount = result.isMounted ? disk.mountPoint : ""
            return result
        }, executeOperation: { _, disk in
            commands.append(disk.uuid)
            if disk.uuid == uuids[0] { return (false, "mount refused") }
            mounted.insert(disk.uuid)
            return (true, "mounted")
        })
        refresh(manager)
        var result: BatchOperationResult?
        manager.performBatch(operation: .mount) { result = $0 }
        expect(manager.isBatchOperating, "batch busy must be published immediately")
        waitUntil("mixed batch must complete") { result != nil }
        expect(commands == [uuids[0], uuids[1]], "first failure must not prevent a later volume; unknown volume must execute no command")
        expect(result?.items.map { $0.status } == [.failed, .succeeded, .skipped], "batch must retain ordered failure, success and skip outcomes")
        expect(result?.message.contains("First") == true && result?.message.contains("mount refused") == true && result?.message.contains("状态未确认") == true, "summary must identify every failure and skipped reason")
        expect(!manager.isBatchOperating && manager.batchResult == result, "finished batch must publish its result before releasing busy")
        print("PASS: batch continues after failure and summarizes successes, failures and unknown skips")
        try "\(uuids[0]):\(target)/single\n".write(to: config, atomically: true, encoding: .utf8)
        var singleMounted = false
        var singleCommands = 0
        let single = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.device = "disk99s1"
            result.isMounted = singleMounted
            result.currentMount = singleMounted ? disk.mountPoint : ""
            return result
        }, executeOperation: { operation, _ in
            singleCommands += 1
            singleMounted = operation == .mount
            return (true, "ok")
        })
        refresh(single)
        var allSuccess: BatchOperationResult?
        single.performBatch(operation: .mount) { allSuccess = $0 }
        waitUntil("all-success batch must finish") { allSuccess != nil }
        expect(allSuccess?.items.map { $0.status } == [.succeeded] && allSuccess?.message == "批量完成：成功 1，失败 0，跳过 0", "all-success batch must report an explicit summary")
        var allSkipped: BatchOperationResult?
        single.performBatch(operation: .mount) { allSkipped = $0 }
        waitUntil("all-skipped batch must finish") { allSkipped != nil }
        expect(allSkipped?.items.map { $0.status } == [.skipped] && singleCommands == 1, "already mounted volumes must skip without executing commands")
        expect(allSkipped?.message.contains("卷已挂载") == true, "all-skipped batch must explain why")
        var allUnmounted: BatchOperationResult?
        single.performBatch(operation: .unmount) { allUnmounted = $0 }
        waitUntil("batch unmount must finish") { allUnmounted != nil }
        expect(allUnmounted?.items.map { $0.status } == [.succeeded] && !single.disks[0].isMounted, "batch unmount must reuse verified single-volume rules")
        print("PASS: all-success, all-skipped and unmount batches have explicit verified results")

        try uuids.map { "\($0):\(target)/\($0)\n" }.joined().write(to: config, atomically: true, encoding: .utf8)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseFinal = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var queryCounts: [String: Int] = [:]
        var currentMounted: Set<String> = []
        var executed: [String] = []
        var executedTargets: [String] = []
        var finalPending = false
        let changing = DiskManager(configURL: config, queryDisk: { disk in
            stateLock.lock()
            queryCounts[disk.uuid, default: 0] += 1
            let count = queryCounts[disk.uuid]!
            let isMounted = currentMounted.contains(disk.uuid)
            stateLock.unlock()
            if disk.uuid == uuids[0] && count == 3 {
                DispatchQueue.main.async { finalPending = true }
                _ = releaseFinal.wait(timeout: .now() + 5)
            }
            var result = disk
            result.device = "disk99s1"
            result.isMounted = isMounted
            result.currentMount = isMounted ? disk.mountPoint : ""
            return result
        }, executeOperation: { _, disk in
            if disk.uuid == uuids[0] {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            stateLock.lock()
            executed.append(disk.uuid)
            executedTargets.append(disk.mountPoint)
            currentMounted.insert(disk.uuid)
            stateLock.unlock()
            return (true, "ok")
        })
        refresh(changing)
        var changedBatch: BatchOperationResult?
        changing.performBatch(operation: .mount) { changedBatch = $0 }
        expect(firstStarted.wait(timeout: .now() + 2) == .success, "first batch command must begin")
        var singleRejection: VolumeOperationResult?
        changing.performOperation(uuid: uuids[1], operation: .mount) { singleRejection = $0 }
        expect(singleRejection?.commandMessage.contains("批量操作") == true, "single-volume requests must not interleave with an active batch")
        var batchRejection: BatchOperationResult?
        changing.performBatch(operation: .mount) { batchRejection = $0 }
        expect(batchRejection?.rejectionReason != nil, "a second batch must not start concurrently")
        expect(changing.deleteDisk(uuid: uuids[1]), "test must remove pending target configuration")
        let newUUID = "42345678-1234-1234-1234-123456789ABC"
        expect(changing.addDisk(uuid: newUUID, mountPoint: target + "/new").success, "new configuration must save during batch")
        expect(changing.updateMountPoint(uuid: uuids[2], newMountPoint: target + "/edited").success, "pending target configuration must be editable through the manager")
        releaseFirst.signal()
        waitUntil("batch must reach final verification") { finalPending }
        expect(changing.isBatchOperating && changedBatch == nil, "final verification must finish before batch releases busy")
        expect(executed == [uuids[0], uuids[2]] && executedTargets.last == target + "/edited", "batch membership must stay fixed, deleted entries skip and remaining entries use current configuration")
        releaseFinal.signal()
        waitUntil("changed-configuration batch must finish") { changedBatch != nil }
        expect(changedBatch?.items.map { $0.uuid } == uuids && changedBatch?.items[1].status == .skipped, "batch summary must retain the original target set and deleted-target reason")
        expect(changing.disks.contains { $0.uuid == newUUID && $0.isStateConfirmed }, "final refresh must include newly added configuration without operating on it")
        expect(!changing.isBatchOperating && !changing.isLoading, "batch and final refresh must both release busy")
        print("PASS: stable batch membership, current configuration checks, competition rejection and final verification")
    }
}
