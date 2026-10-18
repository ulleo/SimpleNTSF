import Foundation
import os.log

// MARK: - Logger

private let logger = Logger(subsystem: "com.simplentfs.app", category: "DiskManager")

private struct OperationExecution {
    var success: Bool
    var message: String
    var commandOutcome: CommandOutcome? = nil
}

// MARK: - Disk Manager

class DiskManager: ObservableObject {
    @Published private(set) var disks: [DiskInfo] = []
    private let fileLock = NSLock()
    private var refreshCompletions: [() -> Void] = []
    // Main-thread revision: a successful configuration write invalidates in-flight queries.
    private var configurationRevision = 0
    private var refreshDeferred = false
    private var isVerifyingBatch = false
    @Published private(set) var isBatchOperating = false
    @Published private(set) var batchResult: BatchOperationResult?
    @Published private(set) var operatingUUIDs: Set<String> = []
    @Published private(set) var operationResults: [String: VolumeOperationResult] = [:]
    private let executeOperation: ((VolumeOperation, DiskInfo) -> (success: Bool, message: String))?
    @Published private(set) var isLoading = false
    @Published private(set) var refreshError: String?
    private let configURL: URL?
    private let queryDisk: ((DiskInfo) throws -> DiskInfo)?
    private let executeCommand: CommandExecuting
    
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
    
    init(configURL: URL? = nil, queryDisk: ((DiskInfo) throws -> DiskInfo)? = nil,
         executeOperation: ((VolumeOperation, DiskInfo) -> (success: Bool, message: String))? = nil,
         executeCommand: CommandExecuting? = nil) {
        self.configURL = configURL
        self.queryDisk = queryDisk
        self.executeOperation = executeOperation
        self.executeCommand = executeCommand ?? { CommandRunner().run(executable: $0, arguments: $1, timeout: $2) }
    }
    
    // MARK: - Validation
    
    func isValidUUID(_ uuid: String) -> Bool {
        let pattern = "^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$"
        return uuid.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
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
        let pattern = "^disk[0-9]+(s[0-9]+)*$"
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
        beginRefresh()
    }

    /// All visible state and revision decisions belong to the main thread.
    private func beginRefresh() {
        guard operatingUUIDs.isEmpty && (!isBatchOperating || isVerifyingBatch) else {
            refreshDeferred = true
            return
        }
        refreshDeferred = false
        let revision = configurationRevision
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
                self.finishRefresh(revision: revision, error: "无法读取挂载配置：\(error.localizedDescription)")
                return
            }

            let lines = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            
            logger.info("配置文件有 \(lines.count) 行有效配置")
            
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let uuid = String(parts[0]).trimmingCharacters(in: .whitespaces).uppercased()
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
                        volumeName: "",
                        mountPoint: normalizedMountPoint,
                        device: "",
                        currentMount: "",
                        isMounted: false,
                        usage: nil,
                        queryState: .unconfirmed(reason: "尚未查询"),
                        hasConfirmedInformation: false
                    )
                    newDisks.append(newDisk)
                }
            }
            
            self.queryDiskInfo(disks: newDisks) { queriedDisks in
                self.finishRefresh(revision: revision, disks: queriedDisks)
            }
        }
    }
    
    private func finishRefresh(revision: Int, disks: [DiskInfo]? = nil, error: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.finishRefresh(revision: revision, disks: disks, error: error) }
            return
        }
        guard revision == configurationRevision else {
            // Keep loading and all waiters until a result for the new configuration is published.
            beginRefresh()
            return
        }
        if let disks = disks {
            self.disks = disks.map { disk in
                guard !disk.isStateConfirmed,
                      var previous = self.disks.first(where: { $0.uuid == disk.uuid && $0.hasConfirmedInformation }) else { return disk }
                previous.mountPoint = disk.mountPoint
                previous.queryState = disk.queryState
                previous.isTimeout = disk.isTimeout
                return previous
            }
        }
        refreshError = error
        isLoading = false
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func queryDiskInfo(disks: [DiskInfo], completion: @escaping ([DiskInfo]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: Result<DiskInfo, VolumeQueryFailure>] = [:]
        for disk in disks {
            group.enter()
            DispatchQueue.global().async {
                let result: Result<DiskInfo, VolumeQueryFailure>
                do {
                    var queried = try self.queryDisk?(disk) ?? self.queryCurrentDisk(disk)
                    if queried.isTimeout { throw VolumeQueryFailure.timedOut }
                    queried.uuid = disk.uuid
                    queried.mountPoint = disk.mountPoint
                    queried.queryState = .confirmed
                    queried.hasConfirmedInformation = true
                    result = .success(queried)
                } catch let failure as VolumeQueryFailure {
                    result = .failure(failure)
                } catch {
                    result = .failure(.failed(error.localizedDescription))
                }
                lock.lock()
                results[disk.uuid] = result
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(disks.map { disk in
                switch results[disk.uuid] {
                case .success(let queried): return queried
                case .failure(let failure):
                    var unknown = disk
                    unknown.queryState = .unconfirmed(reason: failure.message)
                    unknown.isTimeout = failure == .timedOut
                    return unknown
                case nil: return disk
                }
            })
        }
    }

    private func queryCurrentDisk(_ disk: DiskInfo) throws -> DiskInfo {
        try VolumeQuery(execute: executeCommand).refresh(disk)
    }

    // Operation preflight still resolves current metadata by volume UUID.
    func findDevice(byUUID uuid: String) -> String {
        (try? VolumeQuery(execute: executeCommand).details(identifier: uuid).device) ?? "未找到"
    }

    func getFileSystemType(uuid: String) -> String? {
        try? VolumeQuery(execute: executeCommand).details(identifier: uuid).fileSystemType
    }
    /// Freeze membership, then recheck the current configuration and state before each step.
    func performBatch(operation: VolumeOperation, completion: @escaping (BatchOperationResult) -> Void = { _ in }) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.performBatch(operation: operation, completion: completion) }
            return
        }
        guard !isBatchOperating && operatingUUIDs.isEmpty else {
            completion(BatchOperationResult(operation: operation, items: [], rejectionReason: "已有磁盘操作进行中，请稍后重试"))
            return
        }
        let targets = disks
        var results: [BatchVolumeResult] = []
        isBatchOperating = true
        batchResult = nil

        func finish() {
            self.isVerifyingBatch = true
            self.loadConfig {
                let verifiedResults = results.map { item -> BatchVolumeResult in
                    if item.status == .succeeded, let disk = self.disks.first(where: { $0.uuid == item.uuid }), !disk.isStateConfirmed {
                        return BatchVolumeResult(uuid: item.uuid, volumeName: item.volumeName, status: .failed,
                            message: "操作已结束，状态未确认：" + (disk.queryFailureMessage ?? "请刷新重试"), operationResult: item.operationResult)
                    }
                    return item
                }
                let result = BatchOperationResult(operation: operation, items: verifiedResults, refreshError: self.refreshError)
                self.batchResult = result
                self.isVerifyingBatch = false
                self.isBatchOperating = false
                completion(result)
            }
            // A configuration change or user refresh may already be waiting behind this batch.
            if self.refreshDeferred { self.beginRefresh() }
        }

        func next(_ startIndex: Int) {
            var index = startIndex
            while index < targets.count {
                let target = targets[index]
                let current = self.disks.first { $0.uuid == target.uuid }
                let reason: String?
                if current == nil { reason = "挂载配置已删除" }
                else if current?.isStateConfirmed != true { reason = "卷状态未确认，请刷新后重试" }
                else if operation == .mount && current?.canMount != true { reason = "卷已挂载" }
                else if operation != .mount && current?.canUnmount != true { reason = "卷未挂载" }
                else { reason = nil }
                if let reason = reason {
                    results.append(BatchVolumeResult(uuid: target.uuid, volumeName: target.volumeName,
                        status: .skipped, message: reason, operationResult: nil))
                    index += 1
                    continue
                }
                let nextIndex = index + 1
                self.startOperation(uuid: target.uuid, operation: operation, batchStep: true) { outcome in
                    results.append(BatchVolumeResult(uuid: target.uuid, volumeName: target.volumeName,
                        status: outcome.success ? .succeeded : .failed, message: outcome.message, operationResult: outcome))
                    next(nextIndex)
                }
                return
            }
            finish()
        }
        next(0)
    }

    /// The operation remains busy until its actual volume state has been queried and published.
    func performOperation(uuid: String, operation: VolumeOperation,
                          completion: @escaping (VolumeOperationResult) -> Void = { _ in }) {
        startOperation(uuid: uuid, operation: operation, batchStep: false, completion: completion)
    }

    private func startOperation(uuid: String, operation: VolumeOperation, batchStep: Bool,
                                completion: @escaping (VolumeOperationResult) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startOperation(uuid: uuid, operation: operation, batchStep: batchStep, completion: completion) }
            return
        }
        let disk = disks.first { $0.uuid == uuid }
        let rejection: String?
        if isBatchOperating && !batchStep { rejection = "批量操作进行中，请稍后重试" }
        else if operatingUUIDs.contains(uuid) { rejection = "该卷正在操作中，请稍后重试" }
        else if disk?.isStateConfirmed != true { rejection = "卷状态未确认，请刷新后重试" }
        else if operation == .mount && disk?.canMount != true { rejection = "卷已挂载，请使用重新挂载" }
        else if operation != .mount && disk?.canUnmount != true { rejection = "卷未挂载" }
        else { rejection = nil }
        if let rejection = rejection {
            completion(VolumeOperationResult(operation: operation, commandSucceeded: false,
                commandMessage: rejection, queryState: disk?.queryState ?? .unconfirmed(reason: "未找到卷配置")))
            return
        }
        guard let disk = disk else { return }
        operatingUUIDs.insert(uuid)
        operationResults.removeValue(forKey: uuid)
        configurationRevision += 1
        DispatchQueue.global().async {
            var outcome: OperationExecution
            if operation == .remount {
                let unmounted = self.executeStep(.unmount, disk: disk)
                if unmounted.success {
                    let mounted = self.executeStep(.mount, disk: disk)
                    outcome = mounted
                    outcome.message = mounted.success ? "重新挂载成功" : "挂载失败：" + mounted.message
                } else {
                    outcome = unmounted
                    outcome.message = "卸载失败：" + unmounted.message
                }
            } else {
                outcome = self.executeStep(operation, disk: disk)
            }
            self.queryDiskInfo(disks: [disk]) { queried in
                let verified = queried[0]
                if let index = self.disks.firstIndex(where: { $0.uuid == uuid }) {
                    var updated = verified
                    updated.mountPoint = self.disks[index].mountPoint
                    self.disks[index] = updated
                }
                let result = VolumeOperationResult(operation: operation, commandSucceeded: outcome.success,
                    commandMessage: outcome.message, queryState: verified.queryState, commandOutcome: outcome.commandOutcome)
                self.operationResults[uuid] = result
                self.configurationRevision += 1
                self.operatingUUIDs.remove(uuid)
                completion(result)
                if self.operatingUUIDs.isEmpty && self.refreshDeferred { self.beginRefresh() }
            }
        }
    }

    private func executeStep(_ operation: VolumeOperation, disk: DiskInfo) -> OperationExecution {
        if let executeOperation = executeOperation {
            let result = executeOperation(operation, disk)
            return OperationExecution(success: result.success, message: result.message)
        }
        switch operation {
        case .mount: return executeMount(uuid: disk.uuid, mountPoint: disk.mountPoint)
        case .unmount: return executeUnmount(uuid: disk.uuid, mountPoint: disk.currentMount)
        case .remount: preconditionFailure("Remount is coordinated as unmount followed by mount")
        }
    }

    private func executeMount(uuid: String, mountPoint: String) -> OperationExecution {
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(mountPoint) }
        catch { return OperationExecution(success: false, message: error.localizedDescription) }

        
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return OperationExecution(success: false, message: "未找到设备") }
        
        // 验证设备名格式
        guard isValidDeviceName(device) else {
            return OperationExecution(success: false, message: "无效的设备名格式")
        }
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedMountPoint) {
                try fm.createDirectory(atPath: resolvedMountPoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                logger.info("创建挂载点目录：\(resolvedMountPoint)")
            }
        } catch {
            return OperationExecution(success: false, message: "无法创建挂载点目录：\(error.localizedDescription)")
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
        
        let result = executeCommand("/usr/bin/sudo", ["-n", mountCommand] + mountArgs, 15)
        return operationExecution(result, successMessage: "挂载成功！")
    }

    private func executeUnmount(uuid: String, mountPoint: String) -> OperationExecution {
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return OperationExecution(success: false, message: "未找到设备") }
        
        // 验证设备名格式
        guard isValidDeviceName(device) else {
            return OperationExecution(success: false, message: "无效的设备名格式")
        }
        
        let args = ["-n", Constants.diskUtilPath, "unmountDisk", "force", "/dev/" + device]
        let result = executeCommand("/usr/bin/sudo", args, 10)
        return operationExecution(result, successMessage: "卸载成功！")
    }

    private func operationExecution(_ result: CommandResult, successMessage: String) -> OperationExecution {
        var message = result.success ? successMessage : result.message
        let diagnostic = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.success && !diagnostic.isEmpty && !message.contains(diagnostic) {
            message += "；" + diagnostic
        }
        return OperationExecution(success: result.success, message: message, commandOutcome: result.outcome)
    }

    func addDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.addDisk(uuid: uuid, mountPoint: mountPoint) }
        }
        let uuid = uuid.uppercased()
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
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("\(uuid.uppercased()):")
        }) else { return (false, "该卷已存在挂载配置") }
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\(uuid):\(resolvedMountPoint)\n"
        
        do {
            try writeConfiguration(content)
            configurationRevision += 1
            disks.append(DiskInfo(uuid: uuid, volumeName: "", mountPoint: resolvedMountPoint,
                                  device: "", currentMount: "", isMounted: false,
                                  queryState: .unconfirmed(reason: "尚未查询"), hasConfirmedInformation: false))
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
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("\(uuid.uppercased()):") }) else {
            return (false, "未找到挂载配置，请刷新后重试")
        }
        lines[index] = "\(uuid):\(resolvedMountPoint)"

        content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try writeConfiguration(content)
            configurationRevision += 1
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
            if lines[i].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("\(uuid.uppercased()):") {
                lines.remove(at: i)
                break
            }
        }
        
        content = lines.joined(separator: "\n")
        while content.hasSuffix("\n\n") { content.removeLast() }
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try writeConfiguration(content)
            configurationRevision += 1
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
