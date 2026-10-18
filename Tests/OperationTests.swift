import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func waitUntil(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(4)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(predicate(), message)
}
private func refresh(_ manager: DiskManager) {
    var complete = false
    manager.loadConfig { complete = true }
    waitUntil("refresh must finish") { complete }
}

@main
struct OperationTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Test").path
        try "\(uuid):\(target)\n".write(to: config, atomically: true, encoding: .utf8)
        var actualMounted = false
        let queryStarted = DispatchSemaphore(value: 0)
        let releaseQuery = DispatchSemaphore(value: 0)
        var gateQuery = false
        var commandCount = 0
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            if gateQuery {
                queryStarted.signal()
                _ = releaseQuery.wait(timeout: .now() + 4)
            }
            var result = disk
            result.device = "disk99s1"
            result.volumeName = "Test Volume"
            result.isMounted = actualMounted
            result.currentMount = actualMounted ? target : ""
            return result
        }, executeOperation: { operation, _ in
            commandCount += 1
            actualMounted = operation == .mount
            return (true, "command succeeded")
        })
        refresh(manager)
        gateQuery = true
        var completed: VolumeOperationResult?
        manager.performOperation(uuid: uuid.lowercased(), operation: .mount) { completed = $0 }
        expect(manager.operatingUUIDs.contains(uuid), "lowercase volume UUID must start an operation with canonical busy identity")
        expect(queryStarted.wait(timeout: .now() + 2) == .success, "operation must query actual state after its command")
        expect(completed == nil && manager.operatingUUIDs.contains(uuid), "command completion cannot release busy before verification")
        var rejected: VolumeOperationResult?
        manager.performOperation(uuid: uuid, operation: .mount) { rejected = $0 }
        expect(rejected?.commandSucceeded == false && commandCount == 1, "same volume cannot start another operation while verification is pending")
        var deferredRefreshFinished = false
        manager.loadConfig { deferredRefreshFinished = true }
        expect(!deferredRefreshFinished && manager.isLoading, "refresh requested during verification must wait")
        gateQuery = false
        releaseQuery.signal()
        waitUntil("verified operation must finish") { completed != nil }
        expect(manager.disks[0].isMounted && manager.disks[0].isStateConfirmed, "operation completion must observe verified actual state")
        expect(!manager.operatingUUIDs.contains(uuid) && completed?.commandSucceeded == true, "busy ends only after actual state and command outcome are published")
        expect(manager.operationResults[uuid] == completed && manager.operationResults[uuid.lowercased()] == nil, "UUID case must not split the retained operation outcome")
        waitUntil("refresh deferred by an operation must resume") { deferredRefreshFinished }
        expect(!manager.isLoading && manager.disks[0].isMounted, "resumed refresh must retain verified current state")
        print("PASS: case-insensitive single-volume operation owns canonical busy, verification and duplicate rejection")
        var delayedQueries = 0
        var delayedCommands = 0
        let delayed = DiskManager(configURL: config, queryDisk: { disk in
            delayedQueries += 1
            var result = disk
            result.device = "disk99s1"
            result.isMounted = delayedQueries >= 3
            result.currentMount = result.isMounted ? target : ""
            return result
        }, executeOperation: { _, _ in
            delayedCommands += 1
            return (true, "driver started")
        })
        refresh(delayed)
        var delayedResult: VolumeOperationResult?
        delayed.performOperation(uuid: uuid, operation: .mount) { delayedResult = $0 }
        waitUntil("delayed driver mount must reach verified completion") { delayedResult != nil }
        expect(delayedResult?.success == true && delayed.disks[0].isMounted && delayedQueries >= 3,
               "a successful asynchronous mount must wait for the requested actual state")
        expect(delayedCommands == 1, "state verification must not repeat the mount command")
        print("PASS: delayed driver completion polls state without repeating the command")
        var steps: [VolumeOperation] = []
        var failUnmount = true
        var mounted = true
        let remountManager = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.device = "disk99s1"
            result.volumeName = "Remount Volume"
            result.isMounted = mounted
            result.currentMount = mounted ? "/Volumes/Original" : ""
            return result
        }, executeOperation: { operation, _ in
            steps.append(operation)
            if operation == .unmount && failUnmount { return (false, "volume busy") }
            if operation == .unmount { mounted = false; return (true, "unmounted") }
            return (false, "mount refused")
        })
        refresh(remountManager)
        var remounted: VolumeOperationResult?
        remountManager.performOperation(uuid: uuid, operation: .remount) { remounted = $0 }
        waitUntil("failed unmount must finish verification") { remounted != nil }
        expect(steps == [.unmount] && remounted?.commandSucceeded == false && remountManager.disks[0].isMounted, "failed unmount must stop remount and publish verified mounted state")
        failUnmount = false
        steps.removeAll()
        remounted = nil
        remountManager.performOperation(uuid: uuid, operation: .remount) { remounted = $0 }
        waitUntil("partial remount must finish verification") { remounted != nil }
        expect(steps == [.unmount, .mount], "remount must execute each step at most once")
        expect(remounted?.commandMessage.contains("mount refused") == true && !remountManager.disks[0].isMounted, "failed second step must retain its reason and verified unmounted state")
        print("PASS: remount stops after failed unmount and never retries a failed second step")
        var failVerification = false
        var operationMounted = false
        let uncertain = DiskManager(configURL: config, queryDisk: { disk in
            if failVerification { throw VolumeQueryFailure.timedOut }
            var result = disk
            result.device = "disk99s1"
            result.volumeName = "Known Volume"
            result.isMounted = operationMounted
            result.currentMount = operationMounted ? target : ""
            return result
        }, executeOperation: { _, _ in
            operationMounted = true
            failVerification = true
            return (true, "mounted")
        })
        refresh(uncertain)
        var uncertainResult: VolumeOperationResult?
        uncertain.performOperation(uuid: uuid, operation: .mount) { uncertainResult = $0 }
        waitUntil("failed verification must release operation") { uncertainResult != nil }
        expect(uncertainResult?.commandSucceeded == true && uncertainResult?.success == false, "successful command and failed verification must remain separate outcomes")
        expect(!uncertain.disks[0].isStateConfirmed && uncertain.disks[0].hasConfirmedInformation && uncertain.disks[0].volumeName == "Known Volume", "failed post-operation query must retain history as unconfirmed")
        expect(uncertain.operatingUUIDs.isEmpty && !uncertain.disks[0].canMount && !uncertain.disks[0].canUnmount, "failed verification must release busy but keep state-dependent operations disabled")
        failVerification = false
        refresh(uncertain)
        expect(uncertain.disks[0].canUnmount, "refresh after operation-query failure must recover actual state")
        print("PASS: command and verification outcomes are distinct; query failure recovers through refresh")
        let staleStarted = DispatchSemaphore(value: 0)
        let releaseStale = DispatchSemaphore(value: 0)
        let counterLock = NSLock()
        var queryNumber = 0
        var latestMounted = false
        let racing = DiskManager(configURL: config, queryDisk: { disk in
            counterLock.lock()
            queryNumber += 1
            let number = queryNumber
            let capturedMounted = latestMounted
            counterLock.unlock()
            if number == 2 {
                staleStarted.signal()
                _ = releaseStale.wait(timeout: .now() + 4)
            }
            var result = disk
            result.device = "disk99s1"
            result.isMounted = capturedMounted
            result.currentMount = capturedMounted ? target : ""
            return result
        }, executeOperation: { _, _ in
            counterLock.lock(); latestMounted = true; counterLock.unlock()
            return (true, "mounted")
        })
        refresh(racing)
        var staleCompleted = false
        racing.loadConfig {
            expect(racing.disks[0].isMounted, "old refresh waiter must observe the newer verified operation state")
            staleCompleted = true
        }
        expect(staleStarted.wait(timeout: .now() + 2) == .success, "stale query must be in flight")
        var latestComplete = false
        racing.performOperation(uuid: uuid, operation: .mount) { _ in latestComplete = true }
        waitUntil("operation must verify while old refresh is pending") { latestComplete }
        expect(racing.disks[0].isMounted, "verified operation must publish its newer state")
        releaseStale.signal()
        waitUntil("stale refresh must finish with current information") { staleCompleted }
        expect(racing.disks[0].isMounted, "stale refresh cannot overwrite operation verification")
        print("PASS: stale refresh cannot overwrite a newer verified operation")
    }
}
