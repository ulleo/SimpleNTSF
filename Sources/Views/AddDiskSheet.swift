import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.simplentfs.app", category: "AddDiskSheet")

// MARK: - Add Disk Sheet

struct AddDiskSheet: View {
    @Binding var uuid: String
    @Binding var mountPoint: String
    let onSave: () -> (success: Bool, message: String)
    let onCancel: () -> Void
    let addedUUIDs: Set<String>
    
    @State private var discoveredVolumes: [DiscoveredVolume] = []
    @State private var selectedDiskID: String?
    @State private var isLoading = true
    @State private var showManualEntry = false
    @State private var isSelecting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var currentMountHint = ""
    @State private var scanIssues: [String] = []
    
    var body: some View {
        VStack(spacing: 20) {
            Text("➕ 新增卷").font(.title2.bold())
            
            if isLoading {
                ProgressView("正在扫描卷...").padding()
            } else if discoveredVolumes.isEmpty {
                VStack(spacing: 10) {
                    Text(scanIssues.isEmpty ? "⚠️ 未检测到外置卷" : "⚠️ 扫描未完整完成").foregroundColor(.orange)
                    Text("请确保硬盘已连接，或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                    Button("手动输入 UUID", action: { showManualEntry = true }).buttonStyle(.bordered)
                }.padding()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择要挂载的卷：").font(.caption)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(discoveredVolumes) { disk in
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
            
            if !scanIssues.isEmpty {
                ScrollView {
                    Text(scanIssues.joined(separator: "\n"))
                        .font(.caption).foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 70)
                Button("重新扫描", action: loadVolumes).disabled(isLoading)
            }

            if showManualEntry || (selectedDiskID != nil) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("卷 UUID：").font(.caption)
                    TextField("如：E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2", text: $uuid).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("目标挂载点：").font(.caption)
                        if !currentMountHint.isEmpty { Text(currentMountHint).font(.caption).foregroundColor(.blue) }
                    }
                    TextField("如：~/Mounted/ntfs1", text: $mountPoint).textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(spacing: 8) {
                    Text("⬆️ 请从上方列表选择一个卷").font(.caption).foregroundColor(.orange)
                    Text("或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                }.padding(.vertical, 10)
            }
            
            HStack {
                Button("取消", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: {
                    guard !uuid.isEmpty && !mountPoint.isEmpty else {
                        errorMessage = uuid.isEmpty ? "请选择卷或填写 UUID" : "请填写目标挂载点"
                        showError = true
                        return
                    }
                    let result = onSave()
                    if !result.success {
                        errorMessage = result.message
                        showError = true
                    }
                }) {
                    HStack { Image(systemName: "disk"); Text("保存") }
                }.buttonStyle(.borderedProminent)
            }
            .alert("提示", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorMessage) }
            
            Text("💡 获取 UUID：diskutil info /dev/disk4s2 | grep \"Volume UUID\"").font(.caption2).foregroundColor(.secondary)
        }
        .padding(30).frame(width: 500).onAppear { loadVolumes() }
    }
    
    func loadVolumes() {
        isLoading = true
        scanIssues = []
        selectedDiskID = nil
        DispatchQueue.global().async {
            let scan = VolumeQuery().scan(addedUUIDs: addedUUIDs)
            DispatchQueue.main.async {
                self.discoveredVolumes = scan.volumes
                self.scanIssues = scan.issues.map { $0.message }
                self.isLoading = false
            }
        }
    }
}
