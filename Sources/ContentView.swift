import SwiftUI
import Foundation
import os.log

// MARK: - Logger

private let logger = Logger(subsystem: "com.simplentfs.app", category: "DiskManager")

// MARK: - Constants

enum Constants {
    static let configDirName = ".SimpleNTFS"
    static let configFileName = "ntfs-disks.conf"
    static let mountNTFSPath = "/opt/homebrew/sbin/mount_ntfs"
    static let diskUtilPath = "/usr/sbin/diskutil"
    static let sudoersFilePath = "/etc/sudoers.d/simplentfs"
    
    static let forbiddenMountPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var",
        "/Library", "/private", "/Applications", "/Network"
    ]
}

// MARK: - Data Models

struct DiskInfo: Identifiable, Codable, Equatable {
    var uuid: String
    var volumeName: String  // 硬盘名称
    var mountPoint: String
    var device: String
    var currentMount: String
    var isMounted: Bool
    var usage: String?  // 如 "80Gi / 931Gi (9%)"
    
    var id: String { uuid }  // 使用 uuid 作为稳定标识符
    
    init(uuid: String, volumeName: String, mountPoint: String, device: String, currentMount: String, isMounted: Bool, usage: String? = nil) {
        self.uuid = uuid
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.device = device
        self.currentMount = currentMount
        self.isMounted = isMounted
        self.usage = usage
    }
}

struct PhysicalDisk: Identifiable, Codable {
    let id: UUID
    let device: String
    let uuid: String
    let volumeName: String
    let size: String
    var isAdded: Bool
    var currentMount: String?
    
    init(id: UUID = UUID(), device: String, uuid: String, volumeName: String, size: String, isAdded: Bool = false, currentMount: String? = nil) {
        self.id = id
        self.device = device
        self.uuid = uuid
        self.volumeName = volumeName
        self.size = size
        self.isAdded = isAdded
        self.currentMount = currentMount
    }
}

// MARK: - Disk Manager

class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var refreshFlag = false  // 强制刷新标志
    private let fileLock = NSLock()
    private var isLoading = false  // 防止重复加载
    
    var addedUUIDs: Set<String> {
        Set(disks.map { $0.uuid })
    }
    
    let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/\(Constants.configDirName)"
        let configPath = "\(configDir)/\(Constants.configFileName)"
        
        do {
            if !FileManager.default.fileExists(atPath: configDir) {
                try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                logger.info("创建配置目录：\(configDir)")
            }
            
            if !FileManager.default.fileExists(atPath: configPath) {
                let defaultContent = """
                # SimpleNTFS 配置文件
                # 格式：UUID:挂载点路径
                # 使用 diskutil info /dev/diskXsY | grep "Volume UUID" 获取 UUID
                
                """
                try defaultContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                // 设置配置文件权限为 600（仅所有者可读写）
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
                logger.info("创建配置文件并设置权限 600：\(configPath)")
            } else {
                // 验证现有文件权限
                if let attrs = try? FileManager.default.attributesOfItem(atPath: configPath),
                   let perms = attrs[.posixPermissions] as? Int,
                   perms & 0o077 != 0 {
                    logger.warning("配置文件权限不安全（当前：\(String(perms, radix: 8))），建议设为 600")
                }
            }
        } catch {
            logger.error("配置文件初始化失败：\(error.localizedDescription)")
        }
        
        return configPath
    }()
    
    init() {
        // 不在这里调用 loadConfig，由 ContentView.onAppear 调用
    }
    
    // MARK: - Validation
    
    func isValidUUID(_ uuid: String) -> Bool {
        let pattern = "^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$"
        return uuid.range(of: pattern, options: .regularExpression) != nil
    }
    
    func validateMountPoint(_ path: String) -> (valid: Bool, message: String) {
        // 解析 ~ 和相对路径
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardized.path
        
        // 禁止挂载到系统关键目录
        for prefix in Constants.forbiddenMountPrefixes {
            if resolved.hasPrefix(prefix) {
                return (false, "不允许挂载到系统目录：\(prefix)")
            }
        }
        
        // 建议限制在用户目录下
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !resolved.hasPrefix(home) {
            return (false, "挂载点必须位于用户目录下：\(home)")
        }
        
        // 检查路径是否可写
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                return (false, "挂载点已存在但不是目录")
            }
        }
        
        return (true, "")
    }
    
    // MARK: - Config Operations
    
    func loadConfig() {
        print("=== loadConfig 开始 ===")
        
        // 防止重复加载
        guard !isLoading else {
            print("⚠️ 已有加载任务进行中，跳过")
            return
        }
        isLoading = true
        
        // 在后台异步加载配置，避免阻塞 UI
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            defer {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
            
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            
            var newDisks: [DiskInfo] = []
            
            guard FileManager.default.fileExists(atPath: self.configPath) else {
                print("❌ 配置文件不存在：\(self.configPath)")
                return
            }
            
            guard let content = try? String(contentsOfFile: self.configPath, encoding: .utf8),
                  let lines = content.components(separatedBy: "\n").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }).takeIf({ !$0.isEmpty }) else {
                print("❌ 配置文件为空或无法读取")
                return
            }
            
            print("配置文件有 \(lines.count) 行有效配置")
            
            // 第一步：解析配置，创建占位符
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let uuid = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let mountPoint = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    
                    // 验证 UUID 格式
                    guard self.isValidUUID(uuid) else {
                        print("⚠️ 跳过无效的 UUID 格式：\(uuid)")
                        continue
                    }
                    
                    // 验证挂载点
                    let validation = self.validateMountPoint(mountPoint)
                    if !validation.valid {
                        print("⚠️ 跳过无效的挂载点：\(mountPoint) - \(validation.message)")
                        continue
                    }
                    
                    // 创建带占位符的 DiskInfo
                    let newDisk = DiskInfo(
                        uuid: uuid,
                        volumeName: "查询中…",
                        mountPoint: mountPoint,
                        device: "查询中…",
                        currentMount: "查询中…",
                        isMounted: false,
                        usage: nil
                    )
                    newDisks.append(newDisk)
                    print("新：\(uuid.prefix(8))... mountPoint=\(mountPoint)")
                }
            }
            
            // 并行刷新所有设备信息，完成后更新 UI
            print("调用 refreshAllDiskInfoWithCompletion()")
            self.refreshAllDiskInfoWithCompletion(disks: newDisks)
        }
    }
    
    func refreshAllDiskInfo() {
        // 并行获取所有硬盘的设备信息和使用量
        let dispatchGroup = DispatchGroup()
        let infoLock = NSLock()
        var updatedInfo: [String: (device: String, volumeName: String, isMounted: Bool, currentMount: String, usage: String?)] = [:]
        
        // 复制当前 disks 快照，避免遍历时数组变化
        let disksSnapshot = self.disks
        
        print("🔄 开始刷新 \(disksSnapshot.count) 个硬盘的设备信息")
        
        for disk in disksSnapshot {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                let device = self.findDevice(byUUID: disk.uuid)
                let volumeName = self.getVolumeName(byUUID: disk.uuid)
                let actualMount = self.getActualMountPoint(device: device)
                let isMounted = actualMount != nil
                
                // 如果已挂载，获取使用量
                var usage: String? = nil
                if isMounted, let mount = actualMount {
                    usage = self.getDiskUsage(mountPoint: mount)
                }
                
                print("  硬盘 \(disk.uuid.prefix(8)): device=\(device), volume=\(volumeName), mounted=\(isMounted), usage=\(usage ?? "-")")
                
                infoLock.lock()
                updatedInfo[disk.uuid] = (device, volumeName, isMounted, actualMount ?? "-", usage)
                infoLock.unlock()
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            print("设备信息查询完成，开始更新 UI")
            
            // 创建全新数组，一次性更新所有数据
            let newDisks = disksSnapshot.map { oldDisk -> DiskInfo in
                if let info = updatedInfo[oldDisk.uuid] {
                    print("✅ 更新硬盘 \(oldDisk.uuid.prefix(8)): \(oldDisk.device)/\(oldDisk.isMounted) -> \(info.device)/\(info.isMounted), usage=\(info.usage ?? "nil")")
                    return DiskInfo(
                        uuid: oldDisk.uuid,
                        volumeName: info.volumeName,
                        mountPoint: oldDisk.mountPoint,
                        device: info.device,
                        currentMount: info.currentMount,
                        isMounted: info.isMounted,
                        usage: info.usage
                    )
                }
                return oldDisk
            }
            
            self.objectWillChange.send()
            self.disks = newDisks
            self.refreshFlag.toggle()
            // @Published 赋值会自动触发通知，无需手动调用 objectWillChange.send()
            print("所有硬盘设备信息已更新，disks 数组已替换，refreshFlag=\(self.refreshFlag)")
        }
    }
    
    func refreshAllDiskInfoWithCompletion(disks: [DiskInfo]) {
        // 并行获取所有硬盘的设备信息和使用量，完成后一次性更新 UI
        let dispatchGroup = DispatchGroup()
        let infoLock = NSLock()
        var updatedInfo: [String: (device: String, volumeName: String, isMounted: Bool, currentMount: String, usage: String?)] = [:]
        
        print("🔄 开始刷新 \(disks.count) 个硬盘的设备信息（带完成回调）")
        
        for disk in disks {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                let device = self.findDevice(byUUID: disk.uuid)
                let volumeName = self.getVolumeName(byUUID: disk.uuid)
                let actualMount = self.getActualMountPoint(device: device)
                let isMounted = actualMount != nil
                
                // 如果已挂载，获取使用量
                var usage: String? = nil
                if isMounted, let mount = actualMount {
                    usage = self.getDiskUsage(mountPoint: mount)
                }
                
                print("  硬盘 \(disk.uuid.prefix(8)): device=\(device), volume=\(volumeName), mounted=\(isMounted), usage=\(usage ?? "-")")
                
                infoLock.lock()
                updatedInfo[disk.uuid] = (device, volumeName, isMounted, actualMount ?? "-", usage)
                infoLock.unlock()
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            print("设备信息查询完成，开始更新 UI")
            
            // 创建全新数组，一次性更新所有数据
            let newDisks = disks.map { oldDisk -> DiskInfo in
                if let info = updatedInfo[oldDisk.uuid] {
                    print("✅ 更新硬盘 \(oldDisk.uuid.prefix(8)): \(info.device)/\(info.isMounted), usage=\(info.usage ?? "nil")")
                    return DiskInfo(
                        uuid: oldDisk.uuid,
                        volumeName: info.volumeName,
                        mountPoint: oldDisk.mountPoint,
                        device: info.device,
                        currentMount: info.currentMount,
                        isMounted: info.isMounted,
                        usage: info.usage
                    )
                }
                return oldDisk
            }
            
            self.objectWillChange.send()
            self.disks = newDisks
            self.refreshFlag.toggle()
            // @Published 赋值后会自动触发通知
            print("所有硬盘设备信息已更新，disks 数组已替换，refreshFlag=\(self.refreshFlag)")
        }
    }
    
    func findDevice(byUUID uuid: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
        task.arguments = ["info", uuid]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("Device Identifier:") {
                    let parts = line.split(separator: ":")
                    if parts.count == 2 {
                        return String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {
            logger.error("查找设备失败：\(error.localizedDescription)")
        }
        return "未找到"
    }
    
    func getVolumeName(byUUID uuid: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
        task.arguments = ["info", uuid]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("Volume Name:") {
                    let parts = line.split(separator: ":")
                    if parts.count == 2 {
                        return String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {
            logger.error("获取卷名失败：\(error.localizedDescription)")
        }
        return "未知"
    }
    
    func checkMounted(at mountPoint: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(" \(mountPoint) ")
        } catch {
            logger.error("检查挂载状态失败：\(error.localizedDescription)")
        }
        return false
    }
    
    func getActualMountPoint(device: String) -> String? {
        // 检查设备实际挂载在哪里
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("/dev/\(device) ") {
                    // 格式：/dev/diskXsY on /path/to/mount (ntfs, ...)
                    let parts = line.components(separatedBy: " on ")
                    if parts.count >= 2 {
                        let mountPath = parts[1].split(separator: " ").first.map(String.init)
                        return mountPath
                    }
                }
            }
        } catch {
            logger.error("获取实际挂载点失败：\(error.localizedDescription)")
        }
        return nil
    }
    
    func getDiskUsage(mountPoint: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/df")
        task.arguments = ["-h", mountPoint]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // df -h 输出格式：Filesystem Size Used Avail Capacity iused ifree %iused Mounted on
            let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count >= 2 {
                let parts = lines[1].components(separatedBy: " ").filter { !$0.isEmpty }
                if parts.count >= 5 {
                    let used = parts[2]
                    let total = parts[1]
                    let capacity = parts[4]  // 如 "4%"
                    return "\(used) / \(total) (\(capacity))"
                }
            }
        } catch {
            logger.error("获取磁盘使用量失败：\(error.localizedDescription)")
        }
        return nil
    }
    
    func refreshDiskUsages() {
        // 直接在后台线程获取 disks 快照（不再用 sync，避免竞态）
        let disksSnapshot = self.disks
        
        guard !disksSnapshot.isEmpty else { return }
        
        // 并行异步获取所有已挂载磁盘的使用量
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            var updatedUsages: [String: String?] = [:]
            let dispatchGroup = DispatchGroup()
            let usageLock = NSLock()
            
            for disk in disksSnapshot {
                if disk.isMounted {
                    dispatchGroup.enter()
                    DispatchQueue.global().async {
                        let usage = self.getDiskUsage(mountPoint: disk.mountPoint)
                        usageLock.lock()
                        updatedUsages[disk.uuid] = usage
                        usageLock.unlock()
                        dispatchGroup.leave()
                    }
                }
            }
            
            dispatchGroup.notify(queue: .main) {
                // 创建新数组替换，确保 SwiftUI 能检测到变化
                var hasChanges = false
                let newDisks = disksSnapshot.map { disk -> DiskInfo in
                    if let usage = updatedUsages[disk.uuid] {
                        if disk.usage != usage {
                            hasChanges = true
                        }
                        return DiskInfo(
                            uuid: disk.uuid,
                            volumeName: disk.volumeName,
                            mountPoint: disk.mountPoint,
                            device: disk.device,
                            currentMount: disk.currentMount,
                            isMounted: disk.isMounted,
                            usage: usage
                        )
                    } else if !disk.isMounted && disk.usage != nil {
                        // 未挂载的磁盘清空使用量
                        hasChanges = true
                        return DiskInfo(
                            uuid: disk.uuid,
                            volumeName: disk.volumeName,
                            mountPoint: disk.mountPoint,
                            device: disk.device,
                            currentMount: disk.currentMount,
                            isMounted: disk.isMounted,
                            usage: nil
                        )
                    }
                    return disk
                }
                if hasChanges {
                    self.disks = newDisks
                    self.refreshFlag.toggle()
                }
            }
        }
    }
    
    func updateDiskMountStatus(uuid: String, delaySeconds: Double = 0.5, refreshUsageAfterUpdate: Bool = true) {
        // 延时后在后台更新指定硬盘的挂载状态，避免系统状态未及时刷新
        DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self else { return }
            
            // 在后台执行 shell 命令
            let device = self.findDevice(byUUID: uuid)
            let volumeName = self.getVolumeName(byUUID: uuid)
            let actualMount = self.getActualMountPoint(device: device)
            let isMounted = actualMount != nil
            let currentMount = actualMount ?? "-"
            
            logger.info("更新状态：uuid=\(uuid.prefix(8))... device=\(device) mounted=\(isMounted) mount=\(currentMount)")
            
            // 只在主线程更新 UI（需要替换整个数组元素才能触发 SwiftUI 更新）
            DispatchQueue.main.async {
                // 使用 firstIndex 查找，确保找到正确的硬盘
                if let index = self.disks.firstIndex(where: { $0.uuid == uuid }) {
                    let oldDisk = self.disks[index]
                    // 只有状态真的变化时才更新
                    if oldDisk.device != device || oldDisk.volumeName != volumeName || oldDisk.isMounted != isMounted || oldDisk.currentMount != currentMount {
                        self.disks[index] = DiskInfo(
                            uuid: uuid,
                            volumeName: volumeName,
                            mountPoint: oldDisk.mountPoint,
                            device: device,
                            currentMount: currentMount,
                            isMounted: isMounted,
                            usage: oldDisk.usage
                        )
                        logger.info("状态已更新：\(device)")
                    }
                    
                    // 状态更新完成后，刷新使用量（只刷新已挂载的磁盘）
                    if refreshUsageAfterUpdate && isMounted {
                        self.refreshDiskUsages()
                    }
                } else {
                    logger.warning("未找到 uuid=\(uuid.prefix(8))... 的硬盘")
                }
            }
        }
    }
    
    func updateDiskMountPoint(uuid: String, newMountPoint: String) {
        // 就地更新指定硬盘的目标挂载点，需要替换整个数组元素才能触发 SwiftUI 更新
        if let index = disks.firstIndex(where: { $0.uuid == uuid }) {
            let oldDisk = disks[index]
            if oldDisk.mountPoint != newMountPoint {
                disks[index] = DiskInfo(
                    uuid: oldDisk.uuid,
                    volumeName: oldDisk.volumeName,
                    mountPoint: newMountPoint,
                    device: oldDisk.device,
                    currentMount: oldDisk.currentMount,
                    isMounted: oldDisk.isMounted,
                    usage: oldDisk.usage
                )
            }
        }
    }
    
    func mountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        // 展开 ~ 为绝对路径（兼容旧配置文件）
        let expandedMountPoint = (mountPoint as NSString).expandingTildeInPath
        let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
        
        // 验证挂载点
        let validation = validateMountPoint(resolvedMountPoint)
        if !validation.valid {
            return (false, validation.message)
        }
        
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedMountPoint) {
                try fm.createDirectory(atPath: resolvedMountPoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                logger.info("创建挂载点目录：\(resolvedMountPoint)")
            }
        } catch {
            return (false, "无法创建挂载点目录：\(error.localizedDescription)")
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", Constants.mountNTFSPath, "/dev/" + device, resolvedMountPoint]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                logger.info("挂载成功：\(uuid) -> \(mountPoint)")
                return (true, "挂载成功！")
            } else {
                logger.error("挂载失败：\(errorMessage)")
                return (false, errorMessage.isEmpty ? "挂载失败" : errorMessage)
            }
        } catch {
            logger.error("执行挂载命令失败：\(error.localizedDescription)")
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func unmountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", Constants.diskUtilPath, "unmountDisk", "force", "/dev/" + device]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                logger.info("卸载成功：\(uuid)")
                return (true, "卸载成功！")
            } else {
                logger.error("卸载失败：\(errorMessage)")
                return (false, errorMessage.isEmpty ? "卸载失败" : errorMessage)
            }
        } catch {
            logger.error("执行卸载命令失败：\(error.localizedDescription)")
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func addDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        // 验证 UUID 格式
        guard isValidUUID(uuid) else {
            return (false, "无效的 UUID 格式，请使用类似 E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2 的格式")
        }
        
        // 验证挂载点并获取展开后的绝对路径
        let expandedMountPoint = (mountPoint as NSString).expandingTildeInPath
        let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
        let validation = validateMountPoint(mountPoint)
        if !validation.valid {
            return (false, validation.message)
        }
        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        var content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\(uuid):\(resolvedMountPoint)\n"
        
        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            // 确保权限保持 600
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
            logger.info("添加硬盘配置：\(uuid) -> \(resolvedMountPoint)")
            return (true, "")
        } catch {
            logger.error("添加硬盘配置失败：\(error.localizedDescription)")
            return (false, "写入配置文件失败")
        }
    }
    
    func updateMountPoint(uuid: String, newMountPoint: String) -> (success: Bool, message: String) {
        // 验证挂载点并获取展开后的绝对路径
        let expandedMountPoint = (newMountPoint as NSString).expandingTildeInPath
        let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
        let validation = validateMountPoint(newMountPoint)
        if !validation.valid {
            return (false, validation.message)
        }
        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return (false, "读取配置文件失败")
        }
        var lines = content.components(separatedBy: "\n")
        
        for i in 0..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("\(uuid):") {
                lines[i] = "\(uuid):\(resolvedMountPoint)"
                break
            }
        }
        
        content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
            logger.info("更新挂载点：\(uuid) -> \(resolvedMountPoint)")
            return (true, "")
        } catch {
            logger.error("更新挂载点失败：\(error.localizedDescription)")
            return (false, "写入配置文件失败")
        }
    }
    
    func deleteDisk(uuid: String) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        var lines = content.components(separatedBy: "\n")
        
        for i in 0..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("\(uuid):") {
                lines.remove(at: i)
                break
            }
        }
        
        content = lines.joined(separator: "\n")
        while content.hasSuffix("\n\n") { content.removeLast() }
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
            logger.info("删除硬盘配置：\(uuid)")
            return true
        } catch {
            logger.error("删除硬盘配置失败：\(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Helper Extension

extension Sequence {
    func takeIf(_ predicate: (Array<Element>) -> Bool) -> Array<Element>? {
        let result = Array(self)
        return predicate(result) ? result : nil
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = DiskManager()
    @State private var refreshTrigger = false  // 强制刷新标志
    @State private var isRefreshing = false  // 刷新中状态
    @State private var showingAddDialog = false
    @State private var newUUID = ""
    @State private var newMountPoint = ""
    @State private var alertMessage: String?
    @State private var alertIsError = false
    @State private var showingEditDialog = false
    @State private var editingDisk: DiskInfo?
    @State private var showingDeleteConfirm = false
    @State private var deletingDisk: DiskInfo?
    @State private var showingUnmountConfirm = false
    @State private var unmountingDisk: DiskInfo?
    @State private var showingRemountConfirm = false
    @State private var remountingDisk: DiskInfo?
    @State private var isConfiguring = false
    @State private var setupResult: String?
    @State private var setupSuccess = false
    @State private var showingAlert = false
    // Loading 状态管理
    @State private var loadingStates: [String: Bool] = [:]  // UUID -> isLoading
    @State private var isBatchOperating = false  // 批量操作中
    
    var body: some View {
        // 强制刷新标志
        let _ = refreshTrigger
        let _ = manager.refreshFlag
        
        VStack(spacing: 0) {
            // Header with config button
            VStack(spacing: 8) {
                HStack {
                    Text("📀 SimpleNTFS")
                        .font(.title2.bold())
                    Spacer()
                    
                    if !isPasswordFree {
                        Button(action: configureSudoers) {
                            HStack {
                                Image(systemName: "lock.fill").foregroundColor(.orange)
                                Text("配置免密码权限").font(.caption)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.2)).cornerRadius(6)
                        }
                        .disabled(isConfiguring)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("权限已配置").font(.caption).foregroundColor(.green)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.green.opacity(0.2)).cornerRadius(6)
                    }
                }
                
                if let result = setupResult {
                    Text(result).font(.caption).foregroundColor(setupSuccess ? .green : .red)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill").foregroundColor(.blue)
                    Text("需要 macFUSE 支持").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.top).padding(.bottom, 10)
            
            Divider()
            
            // Disk list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(manager.disks, id: \.uuid) { disk in
                        DiskRow(
                            disk: disk,
                            isLoading: loadingStates[disk.uuid] ?? false,
                            isBatchOperating: isBatchOperating,
                            onMount: {
                                guard !isBatchOperating else { return }
                                loadingStates[disk.uuid] = true
                                DispatchQueue.global().async {
                                    let result = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                                    DispatchQueue.main.async {
                                        loadingStates.removeValue(forKey: disk.uuid)
                                        if result.success {
                                            // 延时后刷新所有硬盘状态（多次调用确保刷新）
                                            self.refreshWithLoading()
                                        } else {
                                            alertMessage = result.message
                                            alertIsError = true
                                            showingAlert = true
                                        }
                                    }
                                }
                            },
                            onUnmount: {
                                guard !isBatchOperating else { return }
                                unmountingDisk = disk
                                showingUnmountConfirm = true
                            },
                            onRemount: {
                                guard !isBatchOperating else { return }
                                remountingDisk = disk
                                showingRemountConfirm = true
                            },
                            onEdit: {
                                guard !isBatchOperating && (loadingStates[disk.uuid] ?? false) == false else { return }
                                // 打开编辑前刷新实际挂载状态
                                manager.refreshAllDiskInfo()
                                editingDisk = disk
                                showingEditDialog = true
                            },
                            onDelete: {
                                guard !isBatchOperating && (loadingStates[disk.uuid] ?? false) == false else { return }
                                deletingDisk = disk
                                showingDeleteConfirm = true
                            }
                        )
                    }
                    
                    if manager.disks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "externaldrive").font(.system(size: 48)).foregroundColor(.gray)
                            Text("暂无配置的硬盘").font(.title3).foregroundColor(.secondary)
                            Text("点按「➕ 新增硬盘」开始使用").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 50)
                    }
                }
                .padding(.horizontal).padding(.vertical, 10)
            }
            
            Divider()
            
            // Bottom buttons
            HStack {
                Button(action: { showingAddDialog = true }) {
                    Label("➕ 新增硬盘", systemImage: "plus")
                }
                .disabled(isBatchOperating || loadingStates.values.contains(true))
                Button(action: {
                    print("\n=== 手动刷新按钮被点击 ===")
                    print("刷新前 disks: \(manager.disks.count) 个")
                    for d in manager.disks {
                        print("  \(d.uuid.prefix(8)): device=\(d.device), mounted=\(d.isMounted), usage=\(d.usage ?? "nil")")
                    }
                    manager.loadConfig()
                }) {
                    HStack {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.7)
                        }
                        Label("🔄 刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isBatchOperating || loadingStates.values.contains(true) || isRefreshing)
                Spacer()
                Button(action: {
                    isBatchOperating = true
                    DispatchQueue.global().async {
                        for disk in manager.disks {
                            _ = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        }
                        // 等待系统状态刷新后重新加载配置（多次调用确保刷新）
                        self.refreshWithLoading {
                            isBatchOperating = false
                        }
                    }
                }) {
                    HStack {
                        if isBatchOperating {
                            ProgressView().scaleEffect(0.8)
                        }
                        Label("⬆️ 全部挂载", systemImage: "externaldrive.fill")
                    }
                }
                .disabled(isBatchOperating || loadingStates.values.contains(true))
                Button(action: {
                    isBatchOperating = true
                    DispatchQueue.global().async {
                        for disk in manager.disks {
                            _ = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        }
                        // 等待系统状态刷新后重新加载配置（多次调用确保刷新）
                        self.refreshWithLoading {
                            isBatchOperating = false
                        }
                    }
                }) {
                    HStack {
                        if isBatchOperating {
                            ProgressView().scaleEffect(0.8)
                        }
                        Label("⬇️ 全部卸载", systemImage: "eject.fill")
                    }
                }
                .disabled(isBatchOperating || loadingStates.values.contains(true))
            }
            .padding()
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) {
                alertMessage = nil
                showingAlert = false
            }
        } message: { Text(alertMessage ?? "") }
        .sheet(isPresented: $showingAddDialog) {
            AddDiskSheet(uuid: $newUUID, mountPoint: $newMountPoint, onSave: {
                let result = manager.addDisk(uuid: newUUID, mountPoint: newMountPoint)
                if result.success {
                    // 延时后刷新（多次调用确保刷新）
                    self.refreshWithLoading()
                    showingAddDialog = false
                    newUUID = ""
                    newMountPoint = ""
                } else {
                    alertMessage = result.message
                    alertIsError = true
                    showingAlert = true
                }
            }, onCancel: {
                showingAddDialog = false
                newUUID = ""
                newMountPoint = ""
            }, addedUUIDs: manager.addedUUIDs)
        }
        .sheet(isPresented: $showingEditDialog) {
            EditMountPointSheet(disk: editingDisk, onSave: { newMountPoint in
                if let disk = editingDisk, !newMountPoint.isEmpty {
                    let result = manager.updateMountPoint(uuid: disk.uuid, newMountPoint: newMountPoint)
                    if result.success {
                        // 就地更新挂载点，不重载整个列表
                        manager.updateDiskMountPoint(uuid: disk.uuid, newMountPoint: newMountPoint)
                        showingEditDialog = false
                        editingDisk = nil
                    } else {
                        alertMessage = result.message
                        alertIsError = true
                        showingAlert = true
                    }
                }
            }, onCancel: {
                showingEditDialog = false
                editingDisk = nil
            })
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) { deletingDisk = nil }
            Button("删除", role: .destructive) {
                if let disk = deletingDisk {
                    let success = manager.deleteDisk(uuid: disk.uuid)
                    if success {
                        // 延时后刷新（多次调用确保刷新）
                        self.refreshWithLoading()
                    }
                    deletingDisk = nil
                }
            }
        } message: { Text("确定要从配置列表中删除此硬盘吗？") }
        .alert("确认卸载", isPresented: $showingUnmountConfirm) {
            Button("取消", role: .cancel) { unmountingDisk = nil }
            Button("卸载", role: .destructive) {
                if let disk = unmountingDisk {
                    loadingStates[disk.uuid] = true
                    DispatchQueue.global().async {
                        let result = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.currentMount)
                        DispatchQueue.main.async {
                            loadingStates.removeValue(forKey: disk.uuid)
                            if result.success {
                                // 延时后重新加载配置（多次调用确保刷新）
                                self.refreshWithLoading()
                            } else {
                                alertMessage = result.message
                                alertIsError = true
                                showingAlert = true
                            }
                            unmountingDisk = nil
                        }
                    }
                }
            }
        } message: { Text("确定要卸载此硬盘吗？") }
        .alert("确认重新挂载", isPresented: $showingRemountConfirm) {
            Button("取消", role: .cancel) { remountingDisk = nil }
            Button("重新挂载", role: .destructive) {
                if let disk = remountingDisk {
                    loadingStates[disk.uuid] = true
                    DispatchQueue.global().async {
                        // 先卸载当前挂载
                        let unmountResult = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.currentMount)
                        guard unmountResult.success else {
                            DispatchQueue.main.async {
                                loadingStates.removeValue(forKey: disk.uuid)
                                alertMessage = "卸载失败：" + unmountResult.message
                                alertIsError = true
                                showingAlert = true
                                remountingDisk = nil
                            }
                            return
                        }
                        // 再挂载到目标位置
                        let mountResult = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        DispatchQueue.main.async {
                            loadingStates.removeValue(forKey: disk.uuid)
                            if mountResult.success {
                                // 延时后重新加载配置（多次调用确保刷新）
                                self.refreshWithLoading()
                            } else {
                                alertMessage = "挂载失败：" + mountResult.message
                                alertIsError = true
                                showingAlert = true
                            }
                            remountingDisk = nil
                        }
                    }
                }
            }
        } message: { Text("将先卸载当前挂载，再挂载到目标位置：\n\n\(remountingDisk?.mountPoint ?? "")") }
        .onAppear {
            print("\n=== ContentView.onAppear 被调用 ===")
            // 延时后重新加载配置（多次调用确保刷新）
            self.refreshWithLoading()
        }
    }
    
    var isPasswordFree: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "true"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }
    
    /// 带 loading 状态的刷新（多次调用确保刷新）
    func refreshWithLoading(completion: (() -> Void)? = nil) {
        isRefreshing = true
        manager.loadConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            manager.loadConfig()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            manager.loadConfig()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            manager.loadConfig()
            self.isRefreshing = false
            completion?()
        }
    }
    
    func configureSudoers() {
        isConfiguring = true
        setupResult = "正在配置..."
        
        // 使用当前用户名而非 admin 组，添加 NOEXEC 标签增强安全性
        let currentUser = NSUserName()
        let sudoersEntry = "\(currentUser) ALL=(ALL) NOPASSWD: NOEXEC: \(Constants.mountNTFSPath), \(Constants.diskUtilPath)"
        let sudoersFile = Constants.sudoersFilePath
        
        // 使用临时文件方式，避免字符串拼接注入风险
        let tempFile = "/tmp/simplentfs_sudoers_\(ProcessInfo.processInfo.processIdentifier)"
        
        let script = "echo '\(sudoersEntry)' > '\(tempFile)' && chown root:wheel '\(tempFile)' && chmod 440 '\(tempFile)' && mv '\(tempFile)' '\(sudoersFile)'"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(script)\" with prompt \"SimpleNTFS 需要管理员权限\" with administrator privileges"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        DispatchQueue.global().async {
            do {
                try task.run()
                task.waitUntilExit()
                
                DispatchQueue.main.async {
                    isConfiguring = false
                    if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: sudoersFile) {
                        setupSuccess = true
                        setupResult = "✅ 配置成功！现在挂载/卸载无需密码。"
                        logger.info("Sudoers 配置成功")
                    } else {
                        setupSuccess = false
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        setupResult = "❌ 配置失败：" + (String(data: errorData, encoding: .utf8) ?? "未知错误")
                        logger.error("Sudoers 配置失败")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isConfiguring = false
                    setupSuccess = false
                    setupResult = "❌ 配置失败：" + error.localizedDescription
                    logger.error("Sudoers 配置异常：\(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Disk Row

struct DiskRow: View {
    let disk: DiskInfo
    let isLoading: Bool
    let isBatchOperating: Bool
    let onMount: () -> Void
    let onUnmount: () -> Void
    let onRemount: () -> Void  // 重新挂载
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    private var isDisabled: Bool {
        isLoading || isBatchOperating
    }
    
    private var needsRemount: Bool {
        disk.isMounted && disk.currentMount != disk.mountPoint && !disk.currentMount.isEmpty && disk.currentMount != "-"
    }
    
    private var isRemounting: Bool {
        isLoading && disk.isMounted && needsRemount
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device).font(.system(.body, design: .monospaced))
                    Text(disk.volumeName).font(.system(.body, design: .monospaced)).foregroundColor(.blue)
                    if disk.device == "查询中…" {
                        Text("⏳ 查询中…")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(disk.isMounted ? "✅ 已挂载" : "⭕ 未挂载")
                            .font(.caption).foregroundColor(disk.isMounted ? .green : .orange)
                    }
                }
                Text("UUID: " + disk.uuid).font(.caption).foregroundColor(.secondary)
            }
            .frame(minWidth: 400, maxWidth: 400, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 4) {
                if disk.currentMount == "查询中…" {
                    Text("当前：-").font(.system(.body, design: .monospaced)).foregroundColor(.gray)
                } else {
                    Text("当前：" + disk.currentMount).font(.system(.body, design: .monospaced))
                }
                Text("目标：" + disk.mountPoint).font(.caption).foregroundColor(.secondary)
                if let usage = disk.usage {
                    Text("用量：" + usage).font(.caption).foregroundColor(.blue)
                } else if disk.device == "查询中…" {
                    Text("用量：-").font(.caption).foregroundColor(.gray)
                } else if disk.isMounted {
                    Text("用量：获取中…").font(.caption).foregroundColor(.secondary)
                } else {
                    Text("用量：-").font(.caption).foregroundColor(.gray)
                }
            }
            .frame(width: 250, alignment: .leading)
            
            Spacer()
            
            HStack(spacing: 6) {
                // 挂载按钮（未挂载时可用）
                Button(action: onMount) {
                    HStack {
                        if isLoading && !disk.isMounted {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "externaldrive.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isDisabled || disk.isMounted)
                
                // 卸载按钮（已挂载时可用）
                Button(action: onUnmount) {
                    HStack {
                        if isLoading && disk.isMounted && !needsRemount {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "eject.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isDisabled || !disk.isMounted)
                
                // 重新挂载按钮（挂载点不一致时可用）
                Button(action: onRemount) {
                    HStack {
                        if isRemounting {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(isDisabled || !needsRemount)
                
                // 编辑按钮
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isDisabled)
                
                // 删除按钮
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isDisabled)
            }
            .frame(width: 240, alignment: .center)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: 8).fill(disk.isMounted ? Color.green.opacity(0.05) : Color.clear)))
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

// MARK: - Add Disk Sheet

struct AddDiskSheet: View {
    @Binding var uuid: String
    @Binding var mountPoint: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let addedUUIDs: Set<String>
    
    @State private var physicalDisks: [PhysicalDisk] = []
    @State private var selectedDiskID: UUID?
    @State private var isLoading = true
    @State private var showManualEntry = false
    @State private var isSelecting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var currentMountHint = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("➕ 新增 NTFS 硬盘").font(.title2.bold())
            
            if isLoading {
                ProgressView("正在扫描硬盘...").padding()
            } else if physicalDisks.isEmpty {
                VStack(spacing: 10) {
                    Text("⚠️ 未检测到 NTFS 硬盘").foregroundColor(.orange)
                    Text("请确保硬盘已连接，或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                    Button("手动输入 UUID", action: { showManualEntry = true }).buttonStyle(.bordered)
                }.padding()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择要挂载的硬盘：").font(.caption)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(physicalDisks) { disk in
                                DiskListItem(disk: disk, isSelected: selectedDiskID == disk.id, onSelect: { currentMount in
                                    guard !isSelecting && !disk.isAdded else { return }
                                    isSelecting = true
                                    selectedDiskID = disk.id
                                    uuid = disk.uuid
                                    mountPoint = currentMount
                                    currentMountHint = currentMount.isEmpty ? "" : "（当前：\(currentMount)）"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isSelecting = false }
                                })
                            }
                        }
                    }.frame(height: 150)
                    Button("手动输入 UUID", action: { showManualEntry = true }).font(.caption).buttonStyle(.borderless)
                }
            }
            
            if showManualEntry || (selectedDiskID != nil) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("硬盘 UUID：").font(.caption)
                    TextField("如：E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2", text: $uuid).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("目标挂载点：").font(.caption)
                        if !currentMountHint.isEmpty { Text(currentMountHint).font(.caption).foregroundColor(.blue) }
                    }
                    TextField("如：~/Mounted/ntfs1", text: $mountPoint).textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(spacing: 8) {
                    Text("⬆️ 请从上方列表选择一个硬盘").font(.caption).foregroundColor(.orange)
                    Text("或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                }.padding(.vertical, 10)
            }
            
            HStack {
                Button("取消", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: {
                    guard !uuid.isEmpty && !mountPoint.isEmpty else {
                        errorMessage = uuid.isEmpty ? "请选择硬盘或填写 UUID" : "请填写目标挂载点"
                        showError = true
                        return
                    }
                    // 提前验证路径（展开 ~ 后验证）
                    let expandedMountPoint = (mountPoint as NSString).expandingTildeInPath
                    let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    
                    // 检查是否为用户路径
                    if !resolvedMountPoint.hasPrefix(home) {
                        errorMessage = "挂载点必须位于用户目录下：\(home)"
                        showError = true
                        return
                    }
                    // 检查系统目录
                    for prefix in Constants.forbiddenMountPrefixes {
                        if resolvedMountPoint.hasPrefix(prefix) {
                            errorMessage = "不允许挂载到系统目录：\(prefix)"
                            showError = true
                            return
                        }
                    }
                    onSave()
                }) {
                    HStack { Image(systemName: "disk"); Text("保存") }
                }.buttonStyle(.borderedProminent)
            }
            .alert("提示", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorMessage) }
            
            Text("💡 获取 UUID：diskutil info /dev/disk4s2 | grep \"Volume UUID\"").font(.caption2).foregroundColor(.secondary)
        }
        .padding(30).frame(width: 500).onAppear { loadPhysicalDisks() }
    }
    
    func loadPhysicalDisks() {
        isLoading = true
        DispatchQueue.global().async {
            var disks: [PhysicalDisk] = []
            let task = Process()
            task.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
            task.arguments = ["list"]
            let pipe = Pipe()
            task.standardOutput = pipe
            
            defer {
                pipe.fileHandleForReading.closeFile()
            }
            
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                var currentDisk: String?
                var currentSize: String?
                
                for line in output.components(separatedBy: "\n") {
                    if line.contains("/dev/disk") && line.contains("external") {
                        let parts = line.components(separatedBy: " ")
                        if let device = parts.first { currentDisk = device }
                        if let sizeRange = line.range(of: "\\*?[\\d.]+\\s*[TGMB]B", options: .regularExpression) {
                            currentSize = String(line[sizeRange])
                        }
                    }
                    
                    if currentDisk != nil, line.contains("Microsoft Basic Data") {
                        let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                        if parts.count >= 5 {
                            let device = parts.last ?? ""
                            let volumeName = parts.dropFirst(3).dropLast(2).joined(separator: " ")
                            let size = parts.dropFirst(2).first ?? ""
                            
                            let uuidTask = Process()
                            uuidTask.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
                            uuidTask.arguments = ["info", device]
                            let uuidPipe = Pipe()
                            uuidTask.standardOutput = uuidPipe
                            
                            try? uuidTask.run()
                            uuidTask.waitUntilExit()
                            
                            let uuidData = uuidPipe.fileHandleForReading.readDataToEndOfFile()
                            let uuidOutput = String(data: uuidData, encoding: .utf8) ?? ""
                            
                            var volumeUUID = ""
                            var fileSystemType = ""
                            for uuidLine in uuidOutput.components(separatedBy: "\n") {
                                if uuidLine.contains("Volume UUID:") {
                                    let uuidParts = uuidLine.components(separatedBy: ":")
                                    if uuidParts.count == 2 { volumeUUID = uuidParts[1].trimmingCharacters(in: .whitespaces) }
                                }
                                // 检查文件系统类型，只保留 NTFS
                                if uuidLine.contains("File System Personality:") {
                                    let fsParts = uuidLine.components(separatedBy: ":")
                                    if fsParts.count == 2 { fileSystemType = fsParts[1].trimmingCharacters(in: .whitespaces) }
                                }
                            }
                            
                            // 只添加 NTFS 格式的硬盘
                            if !volumeUUID.isEmpty && fileSystemType == "NTFS" {
                                let isAdded = addedUUIDs.contains(volumeUUID)
                                let currentMount = getCurrentMount(for: device)
                                disks.append(PhysicalDisk(device: device, uuid: volumeUUID, volumeName: volumeName, size: currentSize ?? size, isAdded: isAdded, currentMount: currentMount))
                            }
                        }
                    }
                    
                    if line.isEmpty { currentDisk = nil; currentSize = nil }
                }
            } catch {
                logger.error("扫描硬盘失败：\(error.localizedDescription)")
            }
            
            DispatchQueue.main.async { self.physicalDisks = disks; self.isLoading = false }
        }
    }
    
    func getCurrentMount(for device: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                if line.contains("/dev/\(device) ") {
                    let parts = line.components(separatedBy: " on ")
                    if parts.count >= 2 { return parts[1].split(separator: " ").first.map(String.init) }
                }
            }
        } catch { }
        return nil
    }
}

// MARK: - Disk List Item

struct DiskListItem: View {
    let disk: PhysicalDisk
    let isSelected: Bool
    let onSelect: (String) -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device + " - " + disk.volumeName).font(.system(.body, design: .monospaced))
                    if disk.isAdded { Text("✅ 已添加").font(.caption).foregroundColor(.green) }
                }
                Text("UUID: " + disk.uuid).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(disk.size).font(.caption).foregroundColor(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(disk.isAdded ? Color.green : (isSelected ? Color.blue : Color.gray), lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(disk.isAdded ? Color.green.opacity(0.05) : (isSelected ? Color.blue.opacity(0.1) : Color.clear))))
        .opacity(disk.isAdded ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(disk.currentMount ?? "") }
    }
}

// MARK: - Edit Mount Point Sheet

struct EditMountPointSheet: View {
    let disk: DiskInfo?
    let onSave: (String) -> Void
    let onCancel: () -> Void
    
    @State private var mountPoint = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("✏️ 修改挂载点").font(.title2.bold())
            if let disk = disk {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("硬盘：").font(.caption).foregroundColor(.secondary)
                        Text(disk.device + " - " + String(disk.uuid.prefix(8)) + "...").font(.system(.body, design: .monospaced))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前状态：").font(.caption).foregroundColor(.secondary)
                        if disk.device == "查询中…" {
                            Text("⏳ 查询中…")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text(disk.isMounted ? "✅ 已挂载" : "⭕ 未挂载")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(disk.isMounted ? .green : .orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标挂载点：").font(.caption)
                        TextField("如：~/Mounted/ntfs1", text: $mountPoint).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("取消", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button("保存", action: {
                    let expandedMountPoint = (mountPoint as NSString).expandingTildeInPath
                    let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    
                    if !resolvedMountPoint.hasPrefix(home) {
                        errorMessage = "挂载点必须位于用户目录下：\(home)"
                        showError = true
                        return
                    }
                    for prefix in Constants.forbiddenMountPrefixes {
                        if resolvedMountPoint.hasPrefix(prefix) {
                            errorMessage = "不允许挂载到系统目录：\(prefix)"
                            showError = true
                            return
                        }
                    }
                    onSave(mountPoint)
                }).buttonStyle(.borderedProminent).disabled(mountPoint.isEmpty)
            }
            .alert("提示", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorMessage) }
        }
        .padding(30)
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            if let disk = disk {
                mountPoint = disk.mountPoint
            }
        }
    }
}
