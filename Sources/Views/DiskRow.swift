import SwiftUI

// MARK: - Disk Row

struct DiskRow: View {
    let disk: DiskInfo
    let isLoading: Bool
    let isBatchOperating: Bool
    let onMount: () -> Void
    let onUnmount: () -> Void
    let onRemount: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    private var isDisabled: Bool {
        isLoading || isBatchOperating
    }
    
    private var needsRemount: Bool {
        disk.needsRemount
    }
    
    private var isRemounting: Bool {
        isLoading && disk.isMounted && needsRemount
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 左侧：设备信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device)
                        .font(.system(.body, design: .monospaced))
                    Text(disk.volumeName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue)
                    if disk.isTimeout {
                        Text("⚠️ 获取超时")
                            .font(.caption).foregroundColor(.red)
                    } else if disk.device == "查询中…" {
                        Text("⏳ 查询中…")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(disk.isMounted ? "✅ 已挂载" : "⭕ 未挂载")
                            .font(.caption).foregroundColor(disk.isMounted ? .green : .orange)
                    }
                }
                Text("UUID: " + disk.uuid)
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(minWidth: 200, alignment: .leading)
            
            // 中间：挂载信息
            VStack(alignment: .leading, spacing: 4) {
                if disk.currentMount == "查询中…" {
                    Text("当前：-")
                        .font(.system(.body, design: .monospaced)).foregroundColor(.gray)
                } else {
                    Text("当前：" + disk.currentMount)
                        .font(.system(.body, design: .monospaced))
                }
                Text("目标：" + disk.mountPoint)
                    .font(.caption).foregroundColor(.secondary)
                if let fsType = disk.fileSystemType {
                    Text("类型：" + fsType)
                        .font(.caption).foregroundColor(.purple)
                }
                if let usage = disk.usage {
                    Text("用量：" + usage)
                        .font(.caption).foregroundColor(.blue)
                } else if disk.device == "查询中…" {
                    Text("用量：-")
                        .font(.caption).foregroundColor(.gray)
                } else if disk.isMounted {
                    Text("用量：获取中…")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("用量：-")
                        .font(.caption).foregroundColor(.gray)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            
            Spacer()
            
            // 右侧：操作按钮
            HStack(spacing: 6) {
                // 挂载按钮
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
                .help("挂载")
                
                // 卸载按钮
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
                .help("卸载")
                
                // 重新挂载按钮
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
                .help("重新挂载")
                
                // 编辑按钮
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isDisabled)
                .help("修改挂载点")
                
                // 删除按钮
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isDisabled)
                .help("删除")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(disk.isMounted ? Color.green.opacity(0.05) : Color.clear)
                )
        )
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}
