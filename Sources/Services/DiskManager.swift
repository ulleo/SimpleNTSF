import Foundation
import os.log

// MARK: - Logger

private let logger = Logger(subsystem: "com.simplentfs.app", category: "DiskManager")

private struct OperationExecution {
    var success: Bool
    var message: String
    var commandOutcome: CommandOutcome? = nil
    var authorizationDenied = false
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
    @Published private(set) var authorizationFailures: [String: String] = [:]
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
            var seenUUIDs: Set<String> = []

            let content: String
            do {
                content = try String(contentsOfFile: self.configPath, encoding: .utf8)
            } catch {
                logger.error("配置文件无法读取：\(error.localizedDescription)")
                self.finishRefresh(revision: revision, error: "无法读取挂载配置：\(error.localizedDescription)")
                return
            }

            let lines = content.components(separatedBy: "\n")
            for line in lines {
                if let entry = self.configurationEntry(line) {
                    let uuid = entry.uuid
                    let mountPoint = entry.mountPoint

                    guard let normalizedMountPoint = try? MountPoint.normalize(mountPoint) else {
                        logger.warning("跳过无效的挂载点：\(mountPoint)")
                        continue
                    }
                    
                    guard seenUUIDs.insert(uuid).inserted else { continue }
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
                    var queried = try self.queryDisk?(disk) ?? VolumeQuery(execute: self.executeCommand).refresh(disk)
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

    private enum OperationIneligibility {
        case missingConfiguration, unconfirmedState, alreadyMounted, notMounted

        func message(forBatch: Bool) -> String {
            switch self {
            case .missingConfiguration:
                return forBatch ? "挂载配置已删除" : "卷状态未确认，请刷新后重试"
            case .unconfirmedState:
                return "卷状态未确认，请刷新后重试"
            case .alreadyMounted:
                return forBatch ? "卷已挂载" : "卷已挂载，请使用重新挂载"
            case .notMounted:
                return "卷未挂载"
            }
        }
    }

    /// Both entry paths use the same volume eligibility; busy checks belong to the coordinator.
    private func operationIneligibility(_ disk: DiskInfo?, operation: VolumeOperation) -> OperationIneligibility? {
        guard let disk = disk else { return .missingConfiguration }
        guard disk.isStateConfirmed else { return .unconfirmedState }
        if operation == .mount && !disk.canMount { return .alreadyMounted }
        if operation != .mount && !disk.canUnmount { return .notMounted }
        return nil
    }

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
                if let reason = self.operationIneligibility(current, operation: operation) {
                    results.append(BatchVolumeResult(uuid: target.uuid, volumeName: target.volumeName,
                        status: .skipped, message: reason.message(forBatch: true), operationResult: nil))
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
        let uuid = canonicalUUID(uuid)
        let disk = disks.first { $0.uuid == uuid }
        let rejection: String?
        if isBatchOperating && !batchStep { rejection = "批量操作进行中，请稍后重试" }
        else if operatingUUIDs.contains(uuid) { rejection = "该卷正在操作中，请稍后重试" }
        else { rejection = operationIneligibility(disk, operation: operation)?.message(forBatch: false) }
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
                    commandMessage: outcome.message, queryState: verified.queryState, commandOutcome: outcome.commandOutcome, authorizationDenied: outcome.authorizationDenied)
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
        case .unmount: return executeUnmount(uuid: disk.uuid)
        case .remount: preconditionFailure("Remount is coordinated as unmount followed by mount")
        }
    }

    private func executeMount(uuid: String, mountPoint: String) -> OperationExecution {
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(mountPoint) }
        catch { return OperationExecution(success: false, message: error.localizedDescription) }

        
        let detail: VolumeDetails
        do { detail = try VolumeQuery(execute: executeCommand).details(identifier: uuid) }
        catch let failure as VolumeQueryFailure { return OperationExecution(success: false, message: failure.message) }
        catch { return OperationExecution(success: false, message: error.localizedDescription) }
        guard let fileSystem = VolumeFileSystem(name: detail.fileSystemType) else {
            return OperationExecution(success: false, message: "不支持的文件系统：" + detail.fileSystemType)
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
        
        let mountCommand = fileSystem.mountExecutable
        let arguments = ["-n", mountCommand] + fileSystem.mountArguments(device: detail.device, target: resolvedMountPoint)
        let result = executeCommand("/usr/bin/sudo", arguments, 15)
        return operationExecution(result, command: mountCommand, successMessage: "挂载成功！")
    }

    private func executeUnmount(uuid: String) -> OperationExecution {
        let detail: VolumeDetails
        do { detail = try VolumeQuery(execute: executeCommand).details(identifier: uuid) }
        catch let failure as VolumeQueryFailure { return OperationExecution(success: false, message: failure.message) }
        catch { return OperationExecution(success: false, message: error.localizedDescription) }
        let args = ["-n", Constants.diskUtilPath, "unmount", "/dev/" + detail.device]
        let result = executeCommand("/usr/bin/sudo", args, 10)
        return operationExecution(result, command: Constants.diskUtilPath, successMessage: "卸载成功！")
    }

    private func operationExecution(_ result: CommandResult, command: String, successMessage: String) -> OperationExecution {
        var message = result.success ? successMessage : result.message
        let diagnostic = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.success && !diagnostic.isEmpty && !message.contains(diagnostic) {
            message += "；" + diagnostic
        }
        let denied = PermissionConfiguration.isAuthorizationDenied(result)
        let diagnosticMessage = message
        DispatchQueue.main.async {
            if denied { self.authorizationFailures[command] = diagnosticMessage }
            else if result.success { self.authorizationFailures.removeValue(forKey: command) }
        }
        return OperationExecution(success: result.success, message: message, commandOutcome: result.outcome, authorizationDenied: denied)
    }

    func addDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.addDisk(uuid: uuid, mountPoint: mountPoint) }
        }
        let uuid = canonicalUUID(uuid)
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
            configurationEntry($0)?.uuid == uuid
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
        let uuid = canonicalUUID(uuid)
        let resolvedMountPoint: String
        do { resolvedMountPoint = try MountPoint.normalize(newMountPoint) }
        catch { return (false, error.localizedDescription) }

        
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return (false, "读取配置文件失败")
        }
        var replaced = false
        var lines: [String] = []
        for line in content.components(separatedBy: "\n") {
            if configurationEntry(line)?.uuid == uuid {
                if !replaced { lines.append("\(uuid):\(resolvedMountPoint)" + (line.hasSuffix("\r") ? "\r" : "")) }
                replaced = true
            } else { lines.append(line) }
        }
        guard replaced else { return (false, "未找到挂载配置，请刷新后重试") }
        content = lines.joined(separator: "\n")

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
        let uuid = canonicalUUID(uuid)
        fileLock.lock()
        defer { fileLock.unlock() }
        
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: "\n").filter { configurationEntry($0)?.uuid != uuid }
        content = lines.joined(separator: "\n")

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
    private func canonicalUUID(_ uuid: String) -> String { uuid.uppercased() }

    /// UUID formatting is flexible; the target after the separator retains its actual path bytes.
    private func configurationEntry(_ rawLine: String) -> (uuid: String, mountPoint: String)? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
              let separator = line.firstIndex(of: ":") else { return nil }
        let uuid = canonicalUUID(line[..<separator].trimmingCharacters(in: .whitespaces))
        guard isValidUUID(uuid) else { return nil }
        let path = line[line.index(after: separator)...].drop(while: { $0 == " " || $0 == "\t" })
        return (uuid, String(path))
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
