import Foundation
import os.log

// MARK: - Logger

private let logger = Logger(subsystem: "com.simplentfs.app", category: "DiskManager")

// MARK: - Disk Manager

class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []
    private let fileLock = NSLock()
    private var refreshCompletions: [() -> Void] = []
    @Published private(set) var isLoading = false
    @Published private(set) var refreshError: String?
    private let configURL: URL?
    private let queryDisk: ((DiskInfo) -> DiskInfo)?
    
    var addedUUIDs: Set<String> {
        Set(disks.map { $0.uuid })
    }
    
    private lazy var configPath: String = {
        if let configURL = self.configURL { return configURL.path }
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
    
    init(configURL: URL? = nil, queryDisk: ((DiskInfo) -> DiskInfo)? = nil) {
        self.configURL = configURL
        self.queryDisk = queryDisk
    }
    
    // MARK: - Validation
    
    func isValidUUID(_ uuid: String) -> Bool {
        let pattern = "^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$"
        return uuid.range(of: pattern, options: .regularExpression) != nil
    }
    
    func validateMountPoint(_ path: String) -> (valid: Bool, message: String) {
        do {
            _ = try MountPoint.normalize(path)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    /// 验证设备名格式，防止路径遍历攻击
    func isValidDeviceName(_ device: String) -> Bool {
        // 设备名只能包含字母、数字和斜杠，且必须以 disk 开头
        let pattern = "^disk[0-9]+(s[0-9]+)?$"
        return device.range(of: pattern, options: .regularExpression) != nil
    }
    
    // MARK: - Config Operations
    
    func loadConfig(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadConfig(completion: completion) }
            return
        }
        if let completion = completion { refreshCompletions.append(completion) }
        guard !isLoading else {
            logger.debug("已有加载任务进行中，合并完成通知")
            return
        }
        isLoading = true
        refreshError = nil
        
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            
            var newDisks: [DiskInfo] = []
            
            let content: String
            do {
                content = try String(contentsOfFile: self.configPath, encoding: .utf8)
            } catch {
                logger.error("配置文件无法读取：\(error.localizedDescription)")
                self.finishRefresh(error: "无法读取挂载配置：\(error.localizedDescription)")
                return
            }

            let lines = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            
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
                    
                    guard let normalizedMountPoint = try? MountPoint.normalize(mountPoint) else {
                        logger.warning("跳过无效的挂载点：\(mountPoint)")
                        continue
                    }
                    
                    let newDisk = DiskInfo(
                        uuid: uuid,
                        volumeName: "查询中…",
                        mountPoint: normalizedMountPoint,
                        device: "查询中…",
                        currentMount: "查询中…",
                        isMounted: false,
                        usage: nil
                    )
                    newDisks.append(newDisk)
                }
            }
            
            self.refreshAllDiskInfoWithCompletion(disks: newDisks) {
                self.finishRefresh()
            }
        }
    }
    
    private func finishRefresh(error: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.finishRefresh(error: error) }
            return
        }
        refreshError = error
        isLoading = false
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0() }
    }

    func refreshAllDiskInfo() {
        refreshAllDiskInfoWithCompletion(disks: self.disks)
    }
    
    func refreshAllDiskInfoWithCompletion(disks: [DiskInfo], completion: (() -> Void)? = nil) {
        let dispatchGroup = DispatchGroup()
        let infoLock = NSLock()
        var updatedInfo: [String: (device: String, volumeName: String, isMounted: Bool, currentMount: String, usage: String?, isTimeout: Bool, fileSystemType: String?)] = [:]
        
        logger.info("开始刷新 \(disks.count) 个硬盘的设备信息")
        
        for disk in disks {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                if let queryDisk = self.queryDisk {
                    let result = queryDisk(disk)
                    infoLock.lock()
                    updatedInfo[disk.uuid] = (result.device, result.volumeName, result.isMounted, result.currentMount, result.usage, result.isTimeout, result.fileSystemType)
                    infoLock.unlock()
                    dispatchGroup.leave()
                    return
                }
                var isTimeout = false
                let device = self.runDiskUtilCommand(withTimeout: 3.0, uuid: disk.uuid, searchPattern: "Device Identifier:") {
                    isTimeout = true
                } ?? "未找到"
                let volumeName = self.runDiskUtilCommand(withTimeout: 3.0, uuid: disk.uuid, searchPattern: "Volume Name:") {
                    isTimeout = true
                } ?? "未知"
                let fileSystemType = self.getFileSystemType(uuid: disk.uuid)
                let actualMount = self.getActualMountPoint(device: device)
                let isMounted = actualMount != nil
                
                var usage: String? = nil
                if isMounted, let mount = actualMount {
                    usage = self.getDiskUsage(mountPoint: mount)
                }
                
                infoLock.lock()
                updatedInfo[disk.uuid] = (device, volumeName, isMounted, actualMount ?? "-", usage, isTimeout, fileSystemType)
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
                        isTimeout: info.isTimeout,
                        fileSystemType: info.fileSystemType
                    )
                }
                return oldDisk
            }
            
            self.disks = newDisks
            completion?()
        }
    }
    
    func findDevice(byUUID uuid: String) -> String {
        return runDiskUtilCommand(withTimeout: 3.0, uuid: uuid, searchPattern: "Device Identifier:") ?? "未找到"
    }
    
    func getVolumeName(byUUID uuid: String) -> String {
        return runDiskUtilCommand(withTimeout: 3.0, uuid: uuid, searchPattern: "Volume Name:") ?? "未知"
    }
    
    func getFileSystemType(uuid: String) -> String? {
        return runDiskUtilCommand(withTimeout: 3.0, uuid: uuid, searchPattern: "File System Personality:")
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
    
    func mountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(mountPoint) }
        catch { return (false, error.localizedDescription) }

        
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
        
        // 获取文件系统类型
        let fileSystemType = getFileSystemType(uuid: uuid)
        logger.info("磁盘文件系统类型：\(fileSystemType ?? "未知")")
        
        // 根据文件系统类型选择挂载方式
        let mountCommand: String
        let mountArgs: [String]
        let fsLower = (fileSystemType ?? "").lowercased()
        
        if fsLower.contains("ntfs") {
            // NTFS 使用 macFUSE 的 mount_ntfs
            mountCommand = Constants.mountNTFSPath
            mountArgs = ["/dev/" + device, resolvedMountPoint]
        } else {
            // 其他文件系统（exFAT, FAT32, APFS, HFS+）使用系统原生挂载
            mountCommand = "/sbin/mount"
            let fsFlag = fsLower.contains("exfat") ? ["-t", "exfat"] : 
                         fsLower.contains("fat") ? ["-t", "msdos"] :
                         fsLower.contains("hfs") ? ["-t", "hfs"] : []
            mountArgs = fsFlag + ["/dev/" + device, resolvedMountPoint]
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n"] + [mountCommand] + mountArgs
        
        logger.info("执行挂载命令：sudo -n \(mountCommand) \(mountArgs.joined(separator: " "))")
        
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
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.addDisk(uuid: uuid, mountPoint: mountPoint) }
        }
        guard isValidUUID(uuid) else {
            return (false, "无效的 UUID 格式，请使用类似 E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2 的格式")
        }
        
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(mountPoint) }
        catch { return (false, error.localizedDescription) }

        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return (false, "读取配置文件失败")
        }
        guard !content.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(uuid):")
        }) else { return (false, "该卷已存在挂载配置") }
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\(uuid):\(resolvedMountPoint)\n"
        
        do {
            try writeConfiguration(content)
            disks.append(DiskInfo(uuid: uuid, volumeName: "查询中…", mountPoint: resolvedMountPoint,
                                  device: "查询中…", currentMount: "查询中…", isMounted: false))
            loadConfig()
            logger.info("添加硬盘配置：\(uuid) -> \(resolvedMountPoint)")
            return (true, "")
        } catch {
            logger.error("添加硬盘配置失败：\(error.localizedDescription)")
            return (false, "写入配置文件失败")
        }
    }
    
    func updateMountPoint(uuid: String, newMountPoint: String) -> (success: Bool, message: String) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.updateMountPoint(uuid: uuid, newMountPoint: newMountPoint) }
        }
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(newMountPoint) }
        catch { return (false, error.localizedDescription) }

        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return (false, "读取配置文件失败")
        }
        var lines = content.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(uuid):") }) else {
            return (false, "未找到挂载配置，请刷新后重试")
        }
        lines[index] = "\(uuid):\(resolvedMountPoint)"

        content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try writeConfiguration(content)
            if let index = disks.firstIndex(where: { $0.uuid == uuid }) {
                disks[index].mountPoint = resolvedMountPoint
            }
            logger.info("更新挂载点：\(uuid) -> \(resolvedMountPoint)")
            return (true, "")
        } catch {
            logger.error("更新挂载点失败：\(error.localizedDescription)")
            return (false, "写入配置文件失败")
        }
    }
    
    func deleteDisk(uuid: String) -> Bool {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.deleteDisk(uuid: uuid) }
        }
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
            try writeConfiguration(content)
            disks.removeAll { $0.uuid == uuid }
            logger.info("删除硬盘配置：\(uuid)")
            return true
        } catch {
            logger.error("删除硬盘配置失败：\(error.localizedDescription)")
            return false
        }
    }
    /// Stage content and permissions before atomically replacing the existing configuration.
    /// A failed write or permission change therefore cannot partially commit a save.
    private func writeConfiguration(_ content: String) throws {
        let destination = URL(fileURLWithPath: configPath)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".simplentfs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(content.utf8).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

}
