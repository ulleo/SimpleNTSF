import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
private func fixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Volumes/" + name + ".plist")
    return try! Data(contentsOf: url)
}
private func plist(_ dictionary: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

/// Synthetic outputs: no command reaches diskutil, mount, df or physical media.
private final class VolumeCommands {
    var outputs: [String: CommandResult] = [:]
    var calls: [String] = []
    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult {
        expect(timeout > 0 && timeout <= 5, "every scan/query command must have a finite short deadline")
        let key = arguments.joined(separator: "|")
        calls.append(key)
        if executable == "/bin/df" {
            expect(arguments == ["-h", "/Volumes/Archive: Work Files"], "usage must use complete actual mount path")
            return CommandResult(outcome: .exited(0), stdout: Data("Filesystem Size Used Avail Capacity\n/dev/disk99s1 2Gi 1Gi 1Gi 50%\n".utf8))
        }
        expect(executable == Constants.diskUtilPath, "volume information must use the bounded diskutil adapter")
        return outputs[key] ?? CommandResult(outcome: .exited(1), stderr: Data(("missing fixture " + key).utf8))
    }
}

private final class ConcurrentVolumeCommands {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    let data = fixture("info-ntfs")
    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult {
        lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); active -= 1; lock.unlock()
        return CommandResult(outcome: .exited(0), stdout: data)
    }
}

@main
struct VolumeQueryTests {
    static func main() throws {
        let commands = VolumeCommands()
        commands.outputs["list|-plist"] = CommandResult(outcome: .exited(0), stdout: fixture("list-single"))
        commands.outputs["info|-plist|disk99s1"] = CommandResult(outcome: .exited(0), stdout: fixture("info-ntfs"))
        commands.outputs["info|-plist|ABCDEF12-1234-1234-1234-123456789ABC"] = CommandResult(outcome: .exited(0), stdout: fixture("info-ntfs"))
        let query = VolumeQuery(execute: commands.run)
        let scan = query.scan(addedUUIDs: ["abcdef12-1234-1234-1234-123456789abc"])
        expect(scan.issues.isEmpty && scan.volumes.count == 1, "an external NTFS volume must be discovered")
        let volume = scan.volumes[0]
        expect(volume.volumeName == "Archive: Work Files" && volume.currentMount == "/Volumes/Archive: Work Files", "complete special names and paths must survive discovery")
        expect(volume.isAdded, "added volume comparison must normalize UUID case")
        let configured = DiskInfo(uuid: volume.uuid, volumeName: "", mountPoint: "~/Mounted/Target", device: "", currentMount: "", isMounted: false)
        let refreshed = try query.refresh(configured)
        expect(refreshed.volumeName == volume.volumeName && refreshed.currentMount == volume.currentMount && refreshed.fileSystemType == volume.fileSystemType, "discovery and refresh must share volume details")
        expect(refreshed.mountPoint == configured.mountPoint && refreshed.usage == "1Gi / 2Gi (50%)", "refresh must preserve target and use actual mount for usage")
        expect(commands.calls.filter { $0 == "info|-plist|disk99s1" }.count == 1, "scan must query each device only once")
        expect(commands.calls.filter { $0 == "info|-plist|" + volume.uuid }.count == 1, "refresh must extract all fields from a single detail query")
        print("PASS: scan and refresh share one complete structured detail query per volume")
        let mixed = VolumeCommands()
        let identifiers = ["disk10", "disk11s1", "disk12s1", "disk13s1", "disk14s1", "disk15s1", "disk16s1", "disk17s1", "disk18s1"]
        mixed.outputs["list|-plist"] = CommandResult(outcome: .exited(0), stdout: plist(["AllDisks": identifiers + ["disk10"]]))
        for (index, identifier) in identifiers.enumerated() {
            var raw: [String: Any] = ["DeviceIdentifier": identifier, "VolumeUUID": String(format: "%08X-1234-1234-1234-123456789ABC", index + 1), "VolumeName": "Volume \(index)", "FilesystemType": ["ntfs", "exfat", "msdos", "hfs", "apfs", "ntfs", "ntfs", "ntfs", "ntfs"][index], "Internal": false]
            if index == 5 { raw.removeValue(forKey: "VolumeUUID") }
            if index == 6 { raw.removeValue(forKey: "Internal") }
            if index == 7 { raw["Internal"] = true }
            mixed.outputs["info|-plist|" + identifier] = CommandResult(outcome: .exited(0), stdout: plist(raw))
        }
        mixed.outputs["info|-plist|disk18s1"] = CommandResult(outcome: .timedOut)
        mixed.outputs["apfs|list|-plist"] = CommandResult(outcome: .exited(0), stdout: plist(["Containers": []]))
        let discovered = VolumeQuery(execute: mixed.run).scan()
        expect(Set(discovered.volumes.compactMap { $0.fileSystemType }) == Set(["NTFS", "exFAT", "FAT32", "HFS+", "APFS"]), "all five supported formats including a whole-device volume must be discovered")
        expect(discovered.volumes.allSatisfy { $0.currentMount == nil }, "missing MountPoint on successful info means unmounted")
        expect(discovered.issues.contains { $0.device == "disk15s1" }, "missing volume UUID must be reported")
        expect(discovered.issues.contains { $0.device == "disk16s1" }, "unknown internal/external location must not silently disappear or be treated as external")
        expect(discovered.issues.contains { $0.device == "disk18s1" && $0.failure == .timedOut }, "one timed-out volume must report partial failure without hiding other volumes")
        expect(mixed.calls.filter { $0 == "info|-plist|disk10" }.count == 1, "duplicate enumeration entries must not duplicate detail queries")
        print("PASS: supported formats, whole-device volumes, missing UUID, unknown location and partial timeout")
        let apfs = VolumeCommands()
        apfs.outputs["list|-plist"] = CommandResult(outcome: .exited(0), stdout: plist([
            "AllDisks": ["disk20", "disk20s2", "disk21"],
            "AllDisksAndPartitions": [["DeviceIdentifier": "disk20", "Partitions": [["DeviceIdentifier": "disk20s2", "Content": "Apple_APFS"]]], ["DeviceIdentifier": "disk21"]]
        ]))
        apfs.outputs["info|-plist|disk20"] = CommandResult(outcome: .exited(0), stdout: plist(["DeviceIdentifier": "disk20", "Internal": false, "Whole": true]))
        apfs.outputs["info|-plist|disk20s2"] = CommandResult(outcome: .exited(0), stdout: plist(["DeviceIdentifier": "disk20s2", "ParentWholeDisk": "disk20", "APFSContainerReference": "disk21"]))
        apfs.outputs["info|-plist|disk21"] = CommandResult(outcome: .exited(0), stdout: plist(["DeviceIdentifier": "disk21", "VirtualOrPhysical": "Virtual", "Whole": true]))
        apfs.outputs["apfs|list|-plist"] = CommandResult(outcome: .exited(0), stdout: plist(["Containers": [["ContainerReference": "disk21", "PhysicalStores": [["DeviceIdentifier": "disk20s2"]], "Volumes": [["DeviceIdentifier": "disk21s1"]]]]]))
        apfs.outputs["info|-plist|disk21s1"] = CommandResult(outcome: .exited(0), stdout: plist(["DeviceIdentifier": "disk21s1", "VolumeUUID": "21345678-1234-1234-1234-123456789ABC", "FilesystemType": "apfs", "ParentWholeDisk": "disk21", "APFSContainerReference": "disk21", "VolumeName": "External APFS"]))
        let synthesized = VolumeQuery(execute: apfs.run).scan()
        expect(synthesized.issues.isEmpty && synthesized.volumes.map { $0.device } == ["disk21s1"], "APFS synthesized volume must inherit external provenance from its physical store")
        expect(apfs.calls.filter { $0 == "info|-plist|disk21s1" }.count == 1, "APFS supplemental discovery must not repeat detail queries")
        apfs.outputs["apfs|list|-plist"] = CommandResult(outcome: .timedOut)
        let incomplete = VolumeQuery(execute: apfs.run).scan()
        expect(incomplete.issues.contains { $0.failure == .timedOut }, "APFS supplementary query failure must be reported as incomplete scan")
        print("PASS: APFS synthesized volumes follow physical stores and report incomplete supplementary scans")
        let disconnected = VolumeCommands()
        disconnected.outputs["info|-plist|" + volume.uuid] = CommandResult(outcome: .exited(1))
        disconnected.outputs["list|-plist"] = CommandResult(outcome: .exited(0), stdout: plist(["AllDisks": []]))
        do {
            _ = try VolumeQuery(execute: disconnected.run).refresh(configured)
            fatalError("missing volume must not return fabricated unmounted information")
        } catch let failure as VolumeQueryFailure {
            expect(failure == .offline, "only a successful complete enumeration may establish an offline volume")
        }
        disconnected.outputs["list|-plist"] = CommandResult(outcome: .timedOut)
        do {
            _ = try VolumeQuery(execute: disconnected.run).refresh(configured)
            fatalError("failed enumeration must not confirm absence")
        } catch let failure as VolumeQueryFailure { expect(failure != .offline, "query failure alone is not evidence of unplugging") }
        disconnected.outputs["info|-plist|" + volume.uuid] = CommandResult(outcome: .exited(0), stdout: Data("invalid plist".utf8))
        do {
            _ = try VolumeQuery(execute: disconnected.run).refresh(configured)
            fatalError("malformed detail cannot confirm state")
        } catch let failure as VolumeQueryFailure { expect(failure.message.contains("解析"), "malformed details must have an explicit diagnostic") }
        print("PASS: verified absence, incomplete enumeration and malformed output remain distinct")
        let concurrent = ConcurrentVolumeCommands()
        let group = DispatchGroup()
        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                _ = try? VolumeQuery(execute: concurrent.run).details(identifier: "disk99s1")
                group.leave()
            }
        }
        expect(group.wait(timeout: .now() + 3) == .success, "parallel refresh details must finish")
        expect(concurrent.peak <= 4, "volume query processes must remain bounded across concurrent refreshes")
        print("PASS: concurrent refreshes share a bounded process budget")
        commands.outputs["info|-plist|00000000-1234-1234-1234-123456789ABC"] = CommandResult(outcome: .exited(0), stdout: fixture("info-ntfs"))
        do {
            _ = try query.details(identifier: "00000000-1234-1234-1234-123456789ABC")
            fatalError("a mismatched volume identity must not be accepted for operation preflight")
        } catch let failure as VolumeQueryFailure {
            if case .malformed = failure {} else { fatalError("identity mismatch must be a parse/identity failure") }
        }
        print("PASS: detail lookup rejects mismatched stable volume identity")
    }
}
