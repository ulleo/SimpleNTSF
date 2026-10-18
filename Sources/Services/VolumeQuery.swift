import Foundation

/// Shared supported filesystem names, mount commands and required authorization paths.
enum VolumeFileSystem: String, CaseIterable {
    case ntfs, exfat, fat32, apfs, hfsPlus

    init?(name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ntfs", "windows_ntfs", "windows nt file system (ntfs)": self = .ntfs
        case "exfat": self = .exfat
        case "msdos", "fat32", "ms-dos fat32", "ms-dos (fat32)", "ms-dos fat16": self = .fat32
        case "apfs": self = .apfs
        case "hfs", "hfs+", "jhfs+", "hfsx", "journaled hfs+", "case-sensitive journaled hfs+", "case-sensitive hfs+": self = .hfsPlus
        default: return nil
        }
    }
    var mountExecutable: String { self == .ntfs ? Constants.mountNTFSPath : "/sbin/mount" }

    func mountArguments(device: String, target: String) -> [String] {
        let type: String?
        switch self {
        case .ntfs: type = nil
        case .exfat: type = "exfat"
        case .fat32: type = "msdos"
        case .apfs: type = "apfs"
        case .hfsPlus: type = "hfs"
        }
        return (type.map { ["-t", $0] } ?? []) + ["/dev/" + device, target]
    }

    static var requiredPermissionCommands: [String] {
        var commands: [String] = []
        for fileSystem in allCases where !commands.contains(fileSystem.mountExecutable) {
            commands.append(fileSystem.mountExecutable)
        }
        return commands + [Constants.diskUtilPath]
    }

    var displayName: String {
        switch self {
        case .ntfs: return "NTFS"
        case .exfat: return "exFAT"
        case .fat32: return "FAT32"
        case .apfs: return "APFS"
        case .hfsPlus: return "HFS+"
        }
    }
}

struct VolumeDetails {
    let device: String
    let uuid: String
    let volumeName: String
    let fileSystemType: String
    let currentMount: String?
    let size: Int64?
}

struct VolumeScanIssue {
    let device: String?
    let failure: VolumeQueryFailure
    var message: String { (device.map { $0 + "：" } ?? "") + failure.message }
}

struct VolumeScanResult {
    var volumes: [DiscoveredVolume] = []
    var issues: [VolumeScanIssue] = []
}

/// Owns system output formats. All entry points run on a caller's background queue.
struct VolumeQuery {
    private static let commandSlots = DispatchSemaphore(value: 4)
    private let execute: CommandExecuting
    init(execute: @escaping CommandExecuting = { CommandRunner().run(executable: $0, arguments: $1, timeout: $2) }) {
        self.execute = execute
    }

    func details(identifier: String) throws -> VolumeDetails {
        let detail = try volume(from: info(identifier))
        if let requested = UUID(uuidString: identifier), detail.uuid != requested.uuidString {
            throw VolumeQueryFailure.malformed("卷 UUID 与请求不一致")
        }
        return detail
    }

    func refresh(_ configured: DiskInfo) throws -> DiskInfo {
        let detail: VolumeDetails
        do { detail = try details(identifier: configured.uuid) }
        catch let failure as VolumeQueryFailure {
            // A failed command alone does not establish unplugging. Check a complete fresh inventory.
            guard case .failed = failure,
                  let inventory = try? enumerate(), inventory.issues.isEmpty else { throw failure }
            let volumes = inventory.details.values.filter { fileSystemName($0) != nil }
            guard volumes.allSatisfy({ ($0["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:)) != nil }) else { throw failure }
            if let found = volumes.first(where: { ($0["VolumeUUID"] as? String)?.uppercased() == configured.uuid.uppercased() }) {
                detail = try volume(from: found)
            } else { throw VolumeQueryFailure.offline }
        }
        guard detail.uuid == configured.uuid.uppercased() else { throw VolumeQueryFailure.malformed("卷 UUID 与请求不一致") }
        var result = configured
        result.device = detail.device
        result.volumeName = detail.volumeName
        result.fileSystemType = detail.fileSystemType
        result.currentMount = detail.currentMount ?? ""
        result.isMounted = detail.currentMount != nil
        result.usage = try detail.currentMount.map { try usage(at: $0) }
        return result
    }

    func scan(addedUUIDs: Set<String> = []) -> VolumeScanResult {
        var result = VolumeScanResult()
        do {
            let inventory = try enumerate()
            result.issues = inventory.issues
            let added = Set(addedUUIDs.map { $0.uppercased() })
            var seenUUIDs: Set<String> = []
            for device in inventory.order {
                guard let raw = inventory.details[device], fileSystemName(raw) != nil else { continue }
                do {
                    guard let external = isExternal(device, inventory: inventory) else {
                        throw VolumeQueryFailure.unknownLocation
                    }
                    guard external else { continue }
                    let detail = try volume(from: raw)
                    guard seenUUIDs.insert(detail.uuid).inserted else { continue }
                    result.volumes.append(DiscoveredVolume(device: detail.device, uuid: detail.uuid,
                        volumeName: detail.volumeName,
                        size: detail.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知容量",
                        isAdded: added.contains(detail.uuid), currentMount: detail.currentMount,
                        fileSystemType: detail.fileSystemType))
                } catch let failure as VolumeQueryFailure {
                    result.issues.append(VolumeScanIssue(device: device, failure: failure))
                } catch { result.issues.append(VolumeScanIssue(device: device, failure: .failed(error.localizedDescription))) }
            }
        } catch let failure as VolumeQueryFailure {
            result.issues.append(VolumeScanIssue(device: nil, failure: failure))
        } catch { result.issues.append(VolumeScanIssue(device: nil, failure: .failed(error.localizedDescription))) }
        return result
    }

    private struct Inventory {
        var order: [String] = []
        var details: [String: [String: Any]] = [:]
        var issues: [VolumeScanIssue] = []
        var physicalStores: [String: [String]] = [:]
        var volumeContainers: [String: String] = [:]
    }

    private func enumerate() throws -> Inventory {
        let list = try propertyList(arguments: ["list", "-plist"])
        if let all = list["AllDisks"], !(all is [String]) { throw VolumeQueryFailure.malformed("卷列表") }
        if let nodes = list["AllDisksAndPartitions"], !(nodes is [[String: Any]]) { throw VolumeQueryFailure.malformed("卷列表") }
        guard list["AllDisks"] is [String] || list["AllDisksAndPartitions"] is [[String: Any]] else {
            throw VolumeQueryFailure.malformed("卷列表")
        }
        var identifiers = list["AllDisks"] as? [String] ?? []
        var needsAPFS = false
        func collect(_ dictionary: [String: Any]) {
            if let device = dictionary["DeviceIdentifier"] as? String { identifiers.append(device) }
            if (dictionary["Content"] as? String)?.hasPrefix("Apple_APFS") == true || dictionary["APFSVolumes"] != nil { needsAPFS = true }
            for key in ["AllDisksAndPartitions", "Partitions", "APFSVolumes"] {
                for node in dictionary[key] as? [[String: Any]] ?? [] { collect(node) }
            }
        }
        collect(list)
        var inventory = Inventory()
        var seen: Set<String> = []
        func load(_ device: String) {
            guard seen.insert(device).inserted else { return }
            inventory.order.append(device)
            do {
                let raw = try info(device)
                inventory.details[device] = raw
                if raw["APFSContainerReference"] != nil || fileSystemName(raw).flatMap(VolumeFileSystem.init(name:)) == .apfs { needsAPFS = true }
            } catch let failure as VolumeQueryFailure {
                inventory.issues.append(VolumeScanIssue(device: device, failure: failure))
            } catch { inventory.issues.append(VolumeScanIssue(device: device, failure: .failed(error.localizedDescription))) }
        }
        // Serial queries bound discovery process concurrency to one and cache every device once.
        identifiers.forEach(load)
        if needsAPFS {
            do {
                let apfs = try propertyList(arguments: ["apfs", "list", "-plist"])
                guard let containers = apfs["Containers"] as? [[String: Any]] else { throw VolumeQueryFailure.malformed("APFS 容器关系") }
                for container in containers {
                    guard let reference = container["ContainerReference"] as? String else {
                        throw VolumeQueryFailure.malformed("APFS 容器缺少标识")
                    }
                    let stores = (container["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
                    inventory.physicalStores[reference] = stores
                    stores.forEach(load)
                    for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                        guard let identifier = volume["DeviceIdentifier"] as? String else { continue }
                        inventory.volumeContainers[identifier] = reference
                        load(identifier)
                    }
                }
            } catch let failure as VolumeQueryFailure {
                inventory.issues.append(VolumeScanIssue(device: "APFS", failure: failure))
            } catch { inventory.issues.append(VolumeScanIssue(device: "APFS", failure: .failed(error.localizedDescription))) }
        }
        return inventory
    }

    private func isExternal(_ device: String, inventory: Inventory, visited: Set<String> = []) -> Bool? {
        guard !visited.contains(device) else { return nil }
        var visited = visited
        visited.insert(device)
        let raw = inventory.details[device] ?? [:]
        if let internalVolume = raw["Internal"] as? Bool { return !internalVolume }
        if let stores = inventory.physicalStores[device], !stores.isEmpty {
            let external = stores.map { isExternal($0, inventory: inventory, visited: visited) }
            if external.contains(where: { $0 == false }) { return false }
            return external.allSatisfy { $0 == true } ? true : nil
        }
        for reference in [raw["APFSContainerReference"] as? String,
                          inventory.volumeContainers[device], raw["ParentWholeDisk"] as? String].compactMap({ $0 }) {
            if let external = isExternal(reference, inventory: inventory, visited: visited) { return external }
        }
        return nil
    }

    private func info(_ identifier: String) throws -> [String: Any] {
        let result = try propertyList(arguments: ["info", "-plist", identifier])
        guard let device = result["DeviceIdentifier"] as? String,
              device.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil else {
            throw VolumeQueryFailure.malformed("卷详情缺少有效的设备标识")
        }
        return result
    }

    private func fileSystemName(_ raw: [String: Any]) -> String? {
        (raw["FilesystemType"] as? String) ?? (raw["FilesystemName"] as? String) ?? (raw["FilesystemUserVisibleName"] as? String)
    }

    private func volume(from raw: [String: Any]) throws -> VolumeDetails {
        guard raw["APFSSnapshot"] as? Bool != true else {
            throw VolumeQueryFailure.failed("APFS 快照不能作为普通可写卷操作")
        }
        if (raw["FilesystemName"] as? String)?.lowercased() == "hfs standard" {
            throw VolumeQueryFailure.unsupportedFileSystem("HFS Standard")
        }
        guard let device = raw["DeviceIdentifier"] as? String else { throw VolumeQueryFailure.malformed("缺少设备标识") }
        guard let uuid = raw["VolumeUUID"] as? String, let canonical = UUID(uuidString: uuid)?.uuidString else {
            throw VolumeQueryFailure.missingUUID
        }
        guard let name = fileSystemName(raw), let fileSystem = VolumeFileSystem(name: name) else {
            throw VolumeQueryFailure.unsupportedFileSystem(fileSystemName(raw) ?? "未知")
        }
        if let mount = raw["MountPoint"], !(mount is String) { throw VolumeQueryFailure.malformed("实际挂载点") }
        let mount = raw["MountPoint"] as? String
        return VolumeDetails(device: device, uuid: canonical,
            volumeName: (raw["VolumeName"] as? String) ?? "未命名卷", fileSystemType: fileSystem.displayName,
            currentMount: mount?.isEmpty == false ? mount : nil,
            size: (raw["TotalSize"] as? NSNumber)?.int64Value ?? (raw["VolumeSize"] as? NSNumber)?.int64Value)
    }

    private func propertyList(arguments: [String]) throws -> [String: Any] {
        let data = try output(executable: Constants.diskUtilPath, arguments: arguments)
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { throw VolumeQueryFailure.malformed("plist") }
        return dictionary
    }

    private func output(executable: String, arguments: [String]) throws -> Data {
        Self.commandSlots.wait()
        defer { Self.commandSlots.signal() }
        let result = execute(executable, arguments, 3)
        guard result.success else {
            if result.outcome == .timedOut { throw VolumeQueryFailure.timedOut }
            throw VolumeQueryFailure.failed(result.message)
        }
        return result.stdout
    }

    private func usage(at mount: String) throws -> String {
        let data = try output(executable: "/bin/df", arguments: ["-h", mount])
        guard let output = String(data: data, encoding: .utf8) else { throw VolumeQueryFailure.malformed("卷用量") }
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count >= 2 {
            let parts = lines[1].split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 5 { return "\(parts[2]) / \(parts[1]) (\(parts[4]))" }
        }
        throw VolumeQueryFailure.malformed("卷用量")
    }
}
