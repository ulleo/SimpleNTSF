import SwiftUI

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = DiskManager()
    private var isRefreshing: Bool { manager.isLoading }
    @State private var showingAddDialog = false
    @State private var newUUID = ""
    @State private var newMountPoint = ""
    @State private var notice: OperationNotice?
    @State private var editingDisk: DiskInfo?
    @State private var showingDeleteConfirm = false
    @State private var deletingDisk: DiskInfo?
    @StateObject private var permissionSetup = PermissionSetup()
    private var permissionStatus: PermissionConfiguration.Status { permissionSetup.status }
    private var isPasswordFree: Bool { permissionStatus == .configured && manager.authorizationFailures.isEmpty }
    private var permissionMessage: String {
        guard !manager.authorizationFailures.isEmpty else { return permissionStatus.message }
        return "上次操作授权失败：" + manager.authorizationFailures.keys.sorted().compactMap { manager.authorizationFailures[$0] }.joined(separator: "；")
    }
    private var isBatchOperating: Bool { manager.isBatchOperating }
    
    private var hasLoading: Bool {
        !manager.operatingUUIDs.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with config button
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("📀 SimpleNTFS")
                        .font(.title2.bold())
                    Text("v\(Constants.appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                }
                
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
                        .disabled(permissionSetup.isConfiguring)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(permissionMessage)
                        }
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                    }
                }
                
                if !isPasswordFree {
                    Text(permissionMessage)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }

                if permissionSetup.isConfiguring {
                    Text("正在等待管理员授权…").font(.caption).foregroundColor(.secondary)
                } else if let result = permissionSetup.result {
                    Text(result.message).font(.caption).foregroundColor(result.success ? .green : .red)
                }
            }
            .padding(.top).padding(.bottom, 10)
            
            Divider()

            if let notice = notice {
                OperationNoticeView(notice: notice, onDismiss: { self.notice = nil })
                    .padding(.horizontal)
                    .padding(.top, 10)
            }
            
            if let error = manager.refreshError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .accessibilityLabel("刷新失败：" + error)
            }

            // Disk list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(manager.disks, id: \.uuid) { disk in
                        DiskRow(
                            disk: disk,
                            isLoading: manager.operatingUUIDs.contains(disk.uuid),
                            operationResult: manager.operationResults[disk.uuid],
                            isBatchOperating: isBatchOperating,
                            onMount: {
                                guard !isBatchOperating else { return }
                                operate(uuid: disk.uuid, operation: .mount)
                            },
                            onUnmount: {
                                guard !isBatchOperating else { return }
                                operate(uuid: disk.uuid, operation: .unmount)
                            },
                            onRemount: {
                                guard !isBatchOperating else { return }
                                operate(uuid: disk.uuid, operation: .remount)
                            },
                            onEdit: {
                                guard !isBatchOperating && !manager.operatingUUIDs.contains(disk.uuid) else { return }
                                if let updatedDisk = manager.disks.first(where: { $0.uuid == disk.uuid }) {
                                    editingDisk = updatedDisk
                                }
                            },
                            onDelete: {
                                guard !isBatchOperating && !manager.operatingUUIDs.contains(disk.uuid) else { return }
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
                    runBatch(operation: .mount)
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
                    runBatch(operation: .unmount)
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
        .task(id: notice?.id) {
            guard let current = notice else { return }
            do {
                try await Task.sleep(nanoseconds: current.isError ? 10_000_000_000 : 4_000_000_000)
                if notice?.id == current.id { notice = nil }
            } catch { /* A newer notification or closing the view cancels dismissal. */ }
        }
        .sheet(isPresented: $showingAddDialog) {
            AddDiskSheet(uuid: $newUUID, mountPoint: $newMountPoint, onSave: {
                let result = manager.addDisk(uuid: newUUID, mountPoint: newMountPoint)
                if result.success {
                    showingAddDialog = false
                    newUUID = ""
                    newMountPoint = ""
                }
                return result
            }, onCancel: {
                showingAddDialog = false
                newUUID = ""
                newMountPoint = ""
            }, addedUUIDs: manager.addedUUIDs)
        }
        .sheet(item: $editingDisk) { disk in
            EditMountPointSheet(diskInfo: disk, onSave: { newMountPoint in
                let result = manager.updateMountPoint(uuid: disk.uuid, newMountPoint: newMountPoint)
                if result.success { editingDisk = nil }
                return result
            }, onCancel: {
                editingDisk = nil
            })
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) { deletingDisk = nil }
            Button("删除", role: .destructive) {
                if let disk = deletingDisk {
                    let success = manager.deleteDisk(uuid: disk.uuid)
                    if !success {
                        notice = OperationNotice(message: "删除挂载配置失败，请刷新后重试", isError: true)
                    }
                    deletingDisk = nil
                }
            }
        } message: { Text("确定要从配置列表中删除此硬盘吗？") }
        .onAppear {
            checkPasswordFreeStatus()
            self.refreshWithCompletion()
        }
    }
    
    private func operate(uuid: String, operation: VolumeOperation) {
        let disk = manager.disks.first { $0.uuid == uuid }
        let name = disk.flatMap { $0.volumeName.isEmpty ? nil : $0.volumeName } ?? uuid
        manager.performOperation(uuid: uuid, operation: operation) { result in
            notice = OperationNotice(message: name + "：" + result.message, isError: !result.success)
        }
    }

    private func runBatch(operation: VolumeOperation) {
        manager.performBatch(operation: operation) { result in
            notice = OperationNotice(message: result.message, isError: result.hasFailures)
        }
    }

    func checkPasswordFreeStatus() {
        permissionSetup.refreshStatus()
    }
    
    /// 带 loading 状态的刷新（单次加载，完成后回调）
    func refreshWithCompletion(completion: (() -> Void)? = nil) {
        manager.loadConfig(completion: completion)
    }
    
    func configureSudoers() {
        permissionSetup.configure()
    }
}
