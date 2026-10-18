import SwiftUI

// MARK: - Disk Row

struct DiskRow: View {
    let disk: DiskInfo
    let isLoading: Bool
    let operationResult: VolumeOperationResult?
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
                    Text(disk.device.isEmpty ? "设备待确认" : disk.device)
                        .font(.system(.body, design: .monospaced))
                    Text(disk.volumeName.isEmpty ? "卷信息待确认" : disk.volumeName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue)
                    Text(disk.statusMessage)
                        .font(.caption)
                        .foregroundColor(disk.isStateConfirmed && disk.isMounted ? .green : .orange)

                }
                Text("UUID: " + disk.uuid)
                    .font(.caption).foregroundColor(.secondary)
                if let result = operationResult {
                    Text("上次操作：" + result.message).font(.caption)
                        .foregroundColor(result.success ? .green : .orange)
                }
            }
            .frame(minWidth: 200, alignment: .leading)
            
            // 中间：挂载信息
            VStack(alignment: .leading, spacing: 4) {
                if disk.isStateConfirmed {
                    Text("当前：" + (disk.currentMount.isEmpty ? "未挂载" : disk.currentMount))
                        .font(.system(.body, design: .monospaced))
                } else if disk.hasConfirmedInformation {
                    Text("上次挂载点：" + (disk.currentMount.isEmpty ? "无" : disk.currentMount))
                        .font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
                    Text("上次信息仅供参考，请刷新确认")
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Text("暂无已确认的卷信息")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let reason = disk.queryFailureMessage {
                    Text(reason).font(.caption).foregroundColor(.orange)
                }
                Text("目标：" + disk.mountPoint)
                    .font(.caption).foregroundColor(.secondary)
                if let fsType = disk.fileSystemType {
                    Text("类型：" + fsType)
                        .font(.caption).foregroundColor(.purple)
                }
                if let usage = disk.usage {
                    Text((disk.isStateConfirmed ? "用量：" : "上次用量：") + usage)
                        .font(.caption).foregroundColor(.blue)
                } else {
                    Text("用量：-").font(.caption).foregroundColor(.gray)

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
                .disabled(isDisabled || !disk.canMount)
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
                .disabled(isDisabled || !disk.canUnmount)
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
                        .fill(disk.isStateConfirmed && disk.isMounted ? Color.green.opacity(0.05) : Color.clear)
                )
        )
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}
