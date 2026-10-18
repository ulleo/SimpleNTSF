import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func waitUntil(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(condition(), message)
}

@main
struct RefreshTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let mount = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Test").path
        try "\(uuid):\(mount)\n".write(to: config, atomically: true, encoding: .utf8)
        let queryStarted = DispatchSemaphore(value: 0)
        let releaseQuery = DispatchSemaphore(value: 0)
        let manager = DiskManager(configURL: config, queryDisk: { disk in
            queryStarted.signal()
            _ = releaseQuery.wait(timeout: .now() + 3)
            var result = disk
            result.volumeName = "Test Volume"
            result.device = "disk99s1"
            result.currentMount = "-"
            return result
        })
        var completed = 0
        manager.loadConfig {
            expect(!manager.isLoading, "completion must follow loading release")
            expect(manager.disks.first?.volumeName == "Test Volume", "completion must follow queried list publication")
            completed += 1
        }
        expect(queryStarted.wait(timeout: .now() + 2) == .success, "controlled volume query must start")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(manager.isLoading && completed == 0, "slow volume query must retain loading and completion")
        manager.loadConfig {
            expect(!manager.isLoading, "repeated refresh completion must follow loading release")
            expect(manager.disks.first?.volumeName == "Test Volume", "repeated refresh must observe published query result")
            completed += 1
        }
        expect(completed == 0, "repeated request must not report completion while query is pending")
        releaseQuery.signal()
        waitUntil("both refresh requests must finish exactly once") { completed == 2 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(completed == 2, "each refresh completion fires exactly once")
        print("PASS: slow and repeated refresh completion follows queried volume publication")
        expect(manager.deleteDisk(uuid: uuid), "deleting the only mount configuration must succeed")
        var emptyCompleted = false
        manager.loadConfig {
            expect(manager.disks.isEmpty, "deleting the last mount configuration must clear visible volumes before completion")
            expect(!manager.isLoading, "empty refresh must release loading")
            emptyCompleted = true
        }
        waitUntil("empty configuration refresh must complete") { emptyCompleted }
        print("PASS: deleting the last mount configuration clears volumes")
        try "\(uuid):\(mount)\n".write(to: config, atomically: true, encoding: .utf8)
        let readableManager = DiskManager(configURL: config, queryDisk: { disk in
            var result = disk
            result.volumeName = "Retained Volume"
            return result
        })
        var loaded = false
        readableManager.loadConfig { loaded = true }
        waitUntil("initial readable configuration must finish") { loaded }
        let previous = readableManager.disks
        try Data([0xff, 0xfe, 0xff]).write(to: config)
        var failureCompleted = false
        readableManager.loadConfig {
            expect(readableManager.refreshError?.contains("配置") == true, "configuration read failure must expose an understandable error")
            expect(readableManager.disks == previous, "configuration read failure must retain previously published volumes")
            expect(!readableManager.isLoading, "configuration read failure must release loading")
            failureCompleted = true
        }
        waitUntil("failed configuration refresh must complete") { failureCompleted }
        print("PASS: read failure reports an error and retains existing volume information")
    }
}
