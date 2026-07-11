import Foundation
import os.log

// MARK: - Logger

private let logger = Logger(subsystem: "com.simplentfs.app", category: "DiskManager")

// MARK: - Disk Manager

class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []
    private let fileLock = NSLock()
    private var isLoading = false
    
    var addedUUIDs: Set<String> {
        Set(disks.map { $0.uuid })
    }
    
    private lazy var configPath: String = {
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
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
                logger.info("创建配置文件并设置权限 600：\(configPath)")
            } else {
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
        // 由 ContentView.onAppear 调用 loadConfig
    }
    
    // MARK: - Validation
    
    func isValidUUID(_ uuid: String) -> Bool {
        let pattern = "^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$"
        return uuid.range(of: pattern, options: .regularExpression) != nil
    }
    
    func validateMountPoint(_ path: String) -> (valid: Bool, message: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardized.path
        
        for prefix in Constants.forbiddenMountPrefixes {
            if resolved.hasPrefix(prefix) {
                return (false, "不允许挂载到系统目录：\(prefix)")
            }
        }
        
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !resolved.hasPrefix(home) {
            return (false, "挂载点必须位于用户目录下：\(home)")
        }
        
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                return (false, "挂载点已存在但不是目录")
            }
        }
        
        return (true, "")
    }
    
    /// 验证设备名格式，防止路径遍历攻击
    func isValidDeviceName(_ device: String) -> Bool {
        // 设备名只能包含字母、数字和斜杠，且必须以 disk 开头
        let pattern = "^disk[0-9]+(s[0-9]+)?$"
        return device.range(of: pattern, options: .regularExpression) != nil
    }
    
    // MARK: - Config Operations
    
    func loadConfig(completion: (() -> Void)? = nil) {
        guard !isLoading else {
            logger.debug("已有加载任务进行中，跳过")
            completion?()
            return
        }
        isLoading = true
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            defer {
                DispatchQueue.main.async {
                    self.isLoading = false
                    completion?()
                }
            }
            
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            
            var newDisks: [DiskInfo] = []
            
            guard FileManager.default.fileExists(atPath: self.configPath) else {
                logger.warning("配置文件不存在：\(self.configPath)")
                return
            }
            
            guard let content = try? String(contentsOfFile: self.configPath, encoding: .utf8) else {
                logger.warning("配置文件无法读取")
                return
            }
            
            let lines = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            
            guard !lines.isEmpty else {
                logger.info("配置文件为空")
                return
            }
            
            logger.info("配置文件有 \(lines.count) 行有效配置")
            
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let uuid = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let mountPoint = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    
                    guard self.isValidUUID(uuid) else {
                        logger.warning("跳过无效的 UUID 格式：\(uuid)")
                        continue
                    }
                    
                    let validation = self.validateMountPoint(mountPoint)
                    if !validation.valid {
                        logger.warning("跳过无效的挂载点：\(mountPoint) - \(validation.message)")
                        continue
                    }
                    
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
                }
            }
            
            self.refreshAllDiskInfoWithCompletion(disks: newDisks)
        }
    }
    
    func refreshAllDiskInfo() {
        refreshAllDiskInfoWithCompletion(disks: self.disks)
    }
    
    func refreshAllDiskInfoWithCompletion(disks: [DiskInfo]) {
        let dispatchGroup = DispatchGroup()
        let infoLock = NSLock()
        var updatedInfo: [String: (device: String, volumeName: String, isMounted: Bool, currentMount: String, usage: String?, isTimeout: Bool)] = [:]
        
        logger.info("开始刷新 \(disks.count) 个硬盘的设备信息")
        
        for disk in disks {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                var isTimeout = false
                let device = self.runDiskUtilCommand(withTimeout: 3.0, uuid: disk.uuid, searchPattern: "Device Identifier:") {
                    isTimeout = true
                } ?? "未找到"
                let volumeName = self.runDiskUtilCommand(withTimeout: 3.0, uuid: disk.uuid, searchPattern: "Volume Name:") {
                    isTimeout = true
                } ?? "未知"
                let actualMount = self.getActualMountPoint(device: device)
                let isMounted = actualMount != nil
                
                var usage: String? = nil
                if isMounted, let mount = actualMount {
                    usage = self.getDiskUsage(mountPoint: mount)
                }
                
                infoLock.lock()
                updatedInfo[disk.uuid] = (device, volumeName, isMounted, actualMount ?? "-", usage, isTimeout)
                infoLock.unlock()
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            let newDisks = disks.map { oldDisk -> DiskInfo in
                if let info = updatedInfo[oldDisk.uuid] {
                    return DiskInfo(
                        uuid: oldDisk.uuid,
                        volumeName: info.volumeName,
                        mountPoint: oldDisk.mountPoint,
                        device: info.device,
                        currentMount: info.currentMount,
                        isMounted: info.isMounted,
                        usage: info.usage,
                        isTimeout: info.isTimeout
                    )
                }
                return oldDisk
            }
            
            self.disks = newDisks
        }
    }
    
    func findDevice(byUUID uuid: String) -> String {
        return runDiskUtilCommand(withTimeout: 3.0, uuid: uuid, searchPattern: "Device Identifier:") ?? "未找到"
    }
    
    func getVolumeName(byUUID uuid: String) -> String {
        return runDiskUtilCommand(withTimeout: 3.0, uuid: uuid, searchPattern: "Volume Name:") ?? "未知"
    }
    
    func runDiskUtilCommand(withTimeout timeout: TimeInterval, uuid: String, searchPattern: String, onTimeout: (() -> Void)? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
        task.arguments = ["info", uuid]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }
        
        do {
            try task.run()
            
            let result = semaphore.wait(timeout: .now() + timeout)
            
            if result == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning {
                    task.interrupt()
                    logger.warning("diskutil 命令超时后强制终止 (\(timeout) 秒)，uuid=\(uuid.prefix(8))...")
                }
                onTimeout?()
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains(searchPattern) {
                    let parts = line.split(separator: ":")
                    if parts.count == 2 {
                        return String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {
            logger.error("diskutil 命令失败：\(error.localizedDescription)")
        }
        return nil
    }
    
    func getActualMountPoint(device: String) -> String? {
        return runMountCommand(withTimeout: 2.0, device: device)
    }
    
    func runMountCommand(withTimeout timeout: TimeInterval, device: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        task.standardOutput = pipe
        
        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }
        
        do {
            try task.run()
            
            let result = semaphore.wait(timeout: .now() + timeout)
            
            if result == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning {
                    task.interrupt()
                    logger.warning("mount 命令超时后强制终止 (\(timeout) 秒)，device=\(device)")
                }
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("/dev/\(device) ") {
                    let parts = line.components(separatedBy: " on ")
                    if parts.count >= 2 {
                        return parts[1].split(separator: " ").first.map(String.init)
                    }
                }
            }
        } catch {
            logger.error("获取实际挂载点失败：\(error.localizedDescription)")
        }
        return nil
    }
    
    func getDiskUsage(mountPoint: String) -> String? {
        return runDfCommand(withTimeout: 2.0, mountPoint: mountPoint)
    }
    
    func runDfCommand(withTimeout timeout: TimeInterval, mountPoint: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/df")
        task.arguments = ["-h", mountPoint]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }
        
        do {
            try task.run()
            
            let result = semaphore.wait(timeout: .now() + timeout)
            
            if result == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning {
                    task.interrupt()
                    logger.warning("df 命令超时后强制终止 (\(timeout) 秒)，mountPoint=\(mountPoint)")
                }
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count >= 2 {
                let parts = lines[1].components(separatedBy: " ").filter { !$0.isEmpty }
                if parts.count >= 5 {
                    let used = parts[2]
                    let total = parts[1]
                    let capacity = parts[4]
                    return "\(used) / \(total) (\(capacity))"
                }
            }
        } catch {
            logger.error("获取磁盘使用量失败：\(error.localizedDescription)")
        }
        return nil
    }
    
    func refreshDiskUsages() {
        let disksSnapshot = self.disks
        
        guard !disksSnapshot.isEmpty else { return }
        
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
                }
            }
        }
    }
    
    func updateDiskMountStatus(uuid: String, delaySeconds: Double = 0.5, refreshUsageAfterUpdate: Bool = true) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self else { return }
            
            let device = self.findDevice(byUUID: uuid)
            let volumeName = self.getVolumeName(byUUID: uuid)
            let actualMount = self.getActualMountPoint(device: device)
            let isMounted = actualMount != nil
            let currentMount = actualMount ?? "-"
            
            DispatchQueue.main.async {
                if let index = self.disks.firstIndex(where: { $0.uuid == uuid }) {
                    let oldDisk = self.disks[index]
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
                    }
                    
                    if refreshUsageAfterUpdate && isMounted {
                        self.refreshDiskUsages()
                    }
                }
            }
        }
    }
    
    func updateDiskMountPoint(uuid: String, newMountPoint: String) {
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
        let expandedMountPoint = (mountPoint as NSString).expandingTildeInPath
        let resolvedMountPoint = URL(fileURLWithPath: expandedMountPoint).standardized.path
        
        let validation = validateMountPoint(resolvedMountPoint)
        if !validation.valid {
            return (false, validation.message)
        }
        
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        // 验证设备名格式
        guard isValidDeviceName(device) else {
            return (false, "无效的设备名格式")
        }
        
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
        task.arguments = [
            "-n",
            Constants.mountNTFSPath,
            "/dev/" + device,
            resolvedMountPoint
        ]
        
        logger.info("执行挂载命令：sudo -n \(Constants.mountNTFSPath) /dev/\(device) \(resolvedMountPoint)")
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        // 使用信号量 + 超时，防止无限等待
        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }
        
        do {
            try task.run()
            
            let result = semaphore.wait(timeout: .now() + 15)
            
            if result == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning {
                    task.interrupt()
                }
                pipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()
                logger.warning("挂载命令超时 (15秒)，uuid=\(uuid.prefix(8))...")
                return (false, "挂载超时")
            }
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            
            if task.terminationStatus == 0 {
                logger.info("挂载成功：\(uuid) -> \(mountPoint)")
                return (true, "挂载成功！")
            } else {
                logger.error("挂载失败：\(errorMessage)")
                return (false, errorMessage.isEmpty ? "挂载失败" : errorMessage)
            }
        } catch {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            logger.error("执行挂载命令失败：\(error.localizedDescription)")
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func unmountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        // 验证设备名格式
        guard isValidDeviceName(device) else {
            return (false, "无效的设备名格式")
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let args: [String] = ["-n", Constants.diskUtilPath, "unmountDisk", "force", "/dev/" + device]
        task.arguments = args
        
        logger.info("执行卸载命令：\(args.joined(separator: " "))")
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        // 使用信号量 + 超时，防止无限等待
        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }
        
        do {
            try task.run()
            
            let result = semaphore.wait(timeout: .now() + 10)
            
            if result == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning {
                    task.interrupt()
                }
                pipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()
                logger.warning("卸载命令超时 (10秒)，uuid=\(uuid.prefix(8))...")
                return (false, "卸载超时，磁盘可能被占用")
            }
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            
            if task.terminationStatus == 0 {
                logger.info("卸载成功：\(uuid)")
                return (true, "卸载成功！")
            } else {
                logger.error("卸载失败：\(errorMessage)")
                return (false, errorMessage.isEmpty ? "卸载失败" : errorMessage)
            }
        } catch {
            pipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            logger.error("执行卸载命令失败：\(error.localizedDescription)")
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func addDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        guard isValidUUID(uuid) else {
            return (false, "无效的 UUID 格式，请使用类似 E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2 的格式")
        }
        
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
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
            logger.info("添加硬盘配置：\(uuid) -> \(resolvedMountPoint)")
            return (true, "")
        } catch {
            logger.error("添加硬盘配置失败：\(error.localizedDescription)")
            return (false, "写入配置文件失败")
        }
    }
    
    func updateMountPoint(uuid: String, newMountPoint: String) -> (success: Bool, message: String) {
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
