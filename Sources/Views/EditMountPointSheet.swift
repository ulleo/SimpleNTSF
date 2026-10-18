import SwiftUI

// MARK: - Edit Mount Point Sheet

struct EditMountPointSheet: View {
    let diskInfo: DiskInfo?
    let onSave: (String) -> (success: Bool, message: String)
    let onCancel: () -> Void
    
    @State private var mountPoint = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("✏️ 修改挂载点").font(.title2.bold())
            if let disk = diskInfo {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("硬盘：").font(.caption).foregroundColor(.secondary)
                        Text(disk.device + " - " + String(disk.uuid.prefix(8)) + "...")
                            .font(.system(.body, design: .monospaced))
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
                    let result = onSave(mountPoint)
                    if !result.success {
                        errorMessage = result.message
                        showError = true
                    }
                }).buttonStyle(.borderedProminent).disabled(mountPoint.isEmpty)
            }
            .alert("提示", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorMessage) }
        }
        .padding(30)
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            if let disk = diskInfo {
                mountPoint = disk.mountPoint
            }
        }
    }
}
