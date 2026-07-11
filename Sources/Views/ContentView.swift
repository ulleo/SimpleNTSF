import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.simplentfs.app", category: "ContentView")

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = DiskManager()
    @State private var isRefreshing = false
    @State private var showingAddDialog = false
    @State private var newUUID = ""
    @State private var newMountPoint = ""
    @State private var alertMessage: String?
    @State private var alertIsError = false
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
    @State private var isPasswordFree = false
    @State private var loadingStates: [String: Bool] = [:]
    @State private var isBatchOperating = false
    
    private var hasLoading: Bool {
        loadingStates.values.contains(true)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with config button
            VStack(spacing: 8) {
                Text("📀 SimpleNTFS")
                    .font(.title2.bold())
                
                HStack(spacing: 6) {
                    Button(action: {
                        if let url = URL(string: "https://github.com/ulleo/SimpleNTSF") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle.fill")
                            Text("需要 macFUSE 支持")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Text("｜")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 2)
                    
                    if !isPasswordFree {
                        Button(action: configureSudoers) {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill")
                                Text("配置权限")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isConfiguring)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("已配置权限")
                        }
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                    }
                }
                
                if let result = setupResult {
                    Text(result).font(.caption).foregroundColor(setupSuccess ? .green : .red)
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
                                DispatchQueue.main.async {
                                    loadingStates[disk.uuid] = true
                                }
                                DispatchQueue.global().async {
                                    let result = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                                    DispatchQueue.main.async {
                                        loadingStates.removeValue(forKey: disk.uuid)
                                        if result.success {
                                            self.refreshWithCompletion()
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
                                if let updatedDisk = manager.disks.first(where: { $0.uuid == disk.uuid }) {
                                    editingDisk = updatedDisk
                                }
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
            HStack(spacing: 12) {
                Button(action: { showingAddDialog = true }) {
                    HStack {
                        Label("新增硬盘", systemImage: "plus")
                            .opacity(isBatchOperating || hasLoading ? 0 : 1)
                            .overlay(
                                ProgressView().scaleEffect(0.8)
                                    .opacity(isBatchOperating || hasLoading ? 1 : 0)
                            )
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isBatchOperating || hasLoading)
                
                Button(action: {
                    manager.loadConfig()
                }) {
                    HStack {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .opacity(isRefreshing ? 0 : 1)
                            .overlay(
                                ProgressView().scaleEffect(0.7)
                                    .opacity(isRefreshing ? 1 : 0)
                            )
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .disabled(isBatchOperating || hasLoading || isRefreshing)
                
                Spacer()
                
                Button(action: {
                    isBatchOperating = true
                    DispatchQueue.global().async {
                        for disk in manager.disks {
                            _ = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        }
                        self.refreshWithCompletion {
                            isBatchOperating = false
                        }
                    }
                }) {
                    HStack {
                        Label("全部挂载", systemImage: "externaldrive.fill")
                            .opacity(isBatchOperating ? 0 : 1)
                            .overlay(
                                ProgressView().scaleEffect(0.8)
                                    .opacity(isBatchOperating ? 1 : 0)
                            )
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isBatchOperating || hasLoading)
                
                Button(action: {
                    isBatchOperating = true
                    DispatchQueue.global().async {
                        for disk in manager.disks {
                            _ = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        }
                        self.refreshWithCompletion {
                            isBatchOperating = false
                        }
                    }
                }) {
                    HStack {
                        Label("全部卸载", systemImage: "eject.fill")
                            .opacity(isBatchOperating ? 0 : 1)
                            .overlay(
                                ProgressView().scaleEffect(0.8)
                                    .opacity(isBatchOperating ? 1 : 0)
                            )
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isBatchOperating || hasLoading)
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
                    self.refreshWithCompletion()
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
        .sheet(item: $editingDisk) { disk in
            EditMountPointSheet(diskInfo: disk, onSave: { newMountPoint in
                if !newMountPoint.isEmpty {
                    let result = manager.updateMountPoint(uuid: disk.uuid, newMountPoint: newMountPoint)
                    if result.success {
                        manager.updateDiskMountPoint(uuid: disk.uuid, newMountPoint: newMountPoint)
                        editingDisk = nil
                    } else {
                        alertMessage = result.message
                        alertIsError = true
                        showingAlert = true
                    }
                }
            }, onCancel: {
                editingDisk = nil
            })
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) { deletingDisk = nil }
            Button("删除", role: .destructive) {
                if let disk = deletingDisk {
                    let success = manager.deleteDisk(uuid: disk.uuid)
                    if success {
                        self.refreshWithCompletion()
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
                                self.refreshWithCompletion()
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
                        let mountResult = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        DispatchQueue.main.async {
                            loadingStates.removeValue(forKey: disk.uuid)
                            if mountResult.success {
                                self.refreshWithCompletion()
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
            checkPasswordFreeStatus()
            self.refreshWithCompletion()
        }
    }
    
    func checkPasswordFreeStatus() {
        let fm = FileManager.default
        let sudoersExists = fm.fileExists(atPath: Constants.sudoersFilePath)
        
        DispatchQueue.main.async {
            self.isPasswordFree = sudoersExists
        }
    }
    
    /// 带 loading 状态的刷新（单次加载，完成后回调）
    func refreshWithCompletion(completion: (() -> Void)? = nil) {
        isRefreshing = true
        manager.loadConfig {
            DispatchQueue.main.async {
                self.isRefreshing = false
                completion?()
            }
        }
    }
    
    func configureSudoers() {
        isConfiguring = true
        setupResult = "正在配置..."
        
        // 使用安全的用户名验证，防止注入
        let currentUser = NSUserName()
        let safeName = currentUser.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        
        // 使用 UUID 作为临时文件名，防止预测
        let tempUUID = UUID().uuidString
        let tempFile = "/tmp/simplentfs_sudoers_\(tempUUID)"
        
        let sudoersEntry = "\(safeName) ALL=(ALL) NOPASSWD: NOEXEC: \(Constants.mountNTFSPath), \(Constants.diskUtilPath)"
        let script = "echo '\(sudoersEntry)' > '\(tempFile)' && chown root:wheel '\(tempFile)' && chmod 440 '\(tempFile)' && mv '\(tempFile)' '\(Constants.sudoersFilePath)'"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(script)\" with prompt \"SimpleNTFS 需要管理员权限\" with administrator privileges"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        DispatchQueue.global().async {
            var errorMsg = ""
            do {
                try task.run()
                task.waitUntilExit()
                
                let errorData = errorPipe.fileHandleForReading.availableData
                if !errorData.isEmpty {
                    errorMsg = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                
                pipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()
                
                DispatchQueue.main.async {
                    isConfiguring = false
                    let fileExists = FileManager.default.fileExists(atPath: Constants.sudoersFilePath)
                    
                    if task.terminationStatus == 0 && fileExists {
                        setupSuccess = true
                        setupResult = "✅ 配置成功！现在挂载/卸载无需密码。"
                        logger.info("Sudoers 配置成功")
                        self.checkPasswordFreeStatus()
                    } else {
                        setupSuccess = false
                        let displayError = errorMsg.isEmpty ? "配置失败（退出码：\(task.terminationStatus)）" : errorMsg
                        setupResult = "❌ 配置失败：" + displayError
                        logger.error("Sudoers 配置失败")
                    }
                }
            } catch {
                try? pipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                
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
