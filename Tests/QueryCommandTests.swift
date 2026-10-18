import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func waitUntil(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), message)
}

private final class QueryCommands {
    var failurePath: String?
    var outcome: CommandOutcome = .exited(0)
    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult {
        if executable == failurePath {
            return CommandResult(outcome: outcome, stderr: Data("fixture diagnostic".utf8))
        }
        let output: String
        switch executable {
        case Constants.diskUtilPath:
            guard arguments.first == "info" else { return CommandResult(outcome: .exited(1)) }
            let synthetic: [String: Any] = ["DeviceIdentifier": "disk99s1", "VolumeUUID": "12345678-1234-1234-1234-123456789ABC", "VolumeName": "Test: Volume", "FilesystemType": "ntfs", "MountPoint": "/Volumes/Fixture Disk"]
            return CommandResult(outcome: .exited(0), stdout: try! PropertyListSerialization.data(fromPropertyList: synthetic, format: .xml, options: 0))
        case "/bin/df":
            expect(arguments == ["-h", "/Volumes/Fixture Disk"], "usage must query the actual mount, retaining spaces")
            output = "Filesystem Size Used Avail Capacity\n/dev/disk99s1 2Gi 1Gi 1Gi 50%\n"
        default: fatalError("unexpected command: " + executable)
        }
        return CommandResult(outcome: .exited(0), stdout: Data(output.utf8))
    }
}

@main
struct QueryCommandTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("volumes.conf")
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Target").path
        try "12345678-1234-1234-1234-123456789ABC:\(target)\n".write(to: config, atomically: true, encoding: .utf8)
        let commands = QueryCommands()
        let manager = DiskManager(configURL: config, executeCommand: commands.run)
        func refresh() {
            var completed = false
            manager.loadConfig { completed = true }
            waitUntil("refresh must finish") { completed }
        }
        refresh()
        expect(manager.disks.first?.isStateConfirmed == true, "successful query commands must confirm the volume")
        expect(manager.disks.first?.volumeName == "Test: Volume", "command output fields must retain embedded colons")
        expect(manager.disks.first?.usage == "1Gi / 2Gi (50%)", "usage output must be shown")
        let confirmed = manager.disks[0]
        for path in [Constants.diskUtilPath, "/bin/df"] {
            for failure in [CommandOutcome.exited(7), .launchFailed("fixture missing"), .timedOut, .outputIncomplete] {
                commands.failurePath = path
                commands.outcome = failure
                refresh()
                expect(!manager.disks[0].isStateConfirmed, "every failed query command must mark volume state unconfirmed")
                expect(manager.disks[0].volumeName == confirmed.volumeName && manager.disks[0].currentMount == confirmed.currentMount, "query failure must preserve previous information")
                expect(manager.disks[0].isTimeout == (failure == .timedOut), "only execution timeout must carry timeout state")
                switch failure {
                case .exited: expect(manager.disks[0].queryFailureMessage == "fixture diagnostic", "nonzero exit must expose stderr")
                case .launchFailed: expect(manager.disks[0].queryFailureMessage?.contains("启动失败") == true, "launch failure must remain understandable")
                case .outputIncomplete: expect(manager.disks[0].queryFailureMessage?.contains("未完整") == true, "incomplete output must not masquerade as complete query data")
                default: break
                }
                expect(!manager.disks[0].canMount && !manager.disks[0].canUnmount, "failed command must disable dependent operations")
                commands.failurePath = nil
                refresh()
                expect(manager.disks[0].isStateConfirmed && manager.disks[0].canUnmount, "successful retry must restore confirmed operations")
            }
        }
        print("PASS: structured volume and usage command failures become unconfirmed state and recover on refresh")
    }
}
