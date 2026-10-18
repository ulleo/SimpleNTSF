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
struct ConfigurationCompatibilityTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("legacy.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let manager = DiskManager(configURL: config, queryDisk: { $0 })
        let uuid = "ABCDEF12-1234-1234-1234-123456789ABC"
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Archive: End  ").path
        expect(manager.addDisk(uuid: uuid, mountPoint: target).success, "valid trailing spaces in a directory name must save")
        waitUntil("saved configuration query must finish") { !manager.isLoading }
        expect(manager.disks.first?.mountPoint == target, "save and reload must preserve the full target path including trailing spaces")
        let reloaded = DiskManager(configURL: config, queryDisk: { $0 })
        var finished = false
        reloaded.loadConfig { finished = true }
        waitUntil("fresh manager must load existing config") { finished }
        expect(reloaded.disks.first?.mountPoint == target, "legacy UUID:path format must retain colon and trailing path spaces")
        print("PASS: full target path survives save and reload without a config migration")
        let secondUUID = "BBCDEF12-1234-1234-1234-123456789ABC"
        let unrelated = "# keep this comment exactly\r\n\(secondUUID):~/Mounted/Unrelated\r\n"
        let duplicated = " \(uuid.lowercased()) : \(target)\r\n\(uuid):~/Mounted/Other\r\n" + unrelated
        try duplicated.write(to: config, atomically: true, encoding: .utf8)
        func refresh() {
            finished = false
            reloaded.loadConfig { finished = true }
            waitUntil("legacy configuration reload must finish") { finished }
        }
        refresh()
        expect(reloaded.disks.count == 2 && reloaded.disks[0].mountPoint == target, "duplicate UUIDs must resolve deterministically to the first valid target without duplicate rows")
        expect(!reloaded.addDisk(uuid: uuid.lowercased(), mountPoint: "~/Mounted/Duplicate").success, "formatted and lowercase UUIDs must still prevent duplicate additions")
        print("PASS: legacy CRLF, UUID formatting and duplicate entries load consistently")
        let editedTarget = fm.homeDirectoryForCurrentUser.appendingPathComponent("Mounted/Edited: Name  ").path
        expect(reloaded.updateMountPoint(uuid: uuid.lowercased(), newMountPoint: editedTarget).success, "editing canonical UUID must address all equivalent legacy entries")
        expect(reloaded.disks.first?.mountPoint == editedTarget, "edit must update the canonical visible row")
        refresh()
        expect(reloaded.disks.count == 2 && reloaded.disks.first?.mountPoint == editedTarget, "duplicate lines must not restore the old target after editing")
        let afterEdit = try String(contentsOf: config, encoding: .utf8)
        expect(afterEdit.contains(unrelated), "editing duplicate UUIDs must preserve unrelated lines and comments")
        print("PASS: editing duplicate UUIDs preserves one target and unrelated legacy text")
        try duplicated.write(to: config, atomically: true, encoding: .utf8)
        refresh()
        expect(reloaded.deleteDisk(uuid: uuid.lowercased()), "delete must accept canonical-equivalent UUIDs")
        expect(reloaded.disks.map { $0.uuid } == [secondUUID], "delete must immediately remove the canonical row")
        refresh()
        expect(reloaded.disks.map { $0.uuid } == [secondUUID], "deleted UUID must not return from a duplicate persisted line")
        let afterDelete = try String(contentsOf: config, encoding: .utf8)
        expect(afterDelete == unrelated, "delete must remove all duplicate UUID lines and preserve unrelated bytes")
        print("PASS: deletion removes every equivalent persisted UUID without disturbing other configuration")
    }
}
