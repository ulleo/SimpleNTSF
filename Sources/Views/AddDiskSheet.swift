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
    
    @State private var physicalDisks: [PhysicalDisk] = []
    @State private var selectedDiskID: UUID?
    @State private var isLoading = true
    @State private var showManualEntry = false
    @State private var isSelecting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var currentMountHint = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("➕ 新增硬盘").font(.title2.bold())
            
            if isLoading {
                ProgressView("正在扫描硬盘...").padding()
            } else if physicalDisks.isEmpty {
                VStack(spacing: 10) {
                    Text("⚠️ 未检测到外置硬盘").foregroundColor(.orange)
                    Text("请确保硬盘已连接，或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                    Button("手动输入 UUID", action: { showManualEntry = true }).buttonStyle(.bordered)
                }.padding()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择要挂载的硬盘：").font(.caption)
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(physicalDisks) { disk in
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
            
            if showManualEntry || (selectedDiskID != nil) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("硬盘 UUID：").font(.caption)
                    TextField("如：E0719CA3-71B2-12E0-A9E0-12B4EA12B4C2", text: $uuid).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("目标挂载点：").font(.caption)
                        if !currentMountHint.isEmpty { Text(currentMountHint).font(.caption).foregroundColor(.blue) }
                    }
                    TextField("如：~/Mounted/ntfs1", text: $mountPoint).textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(spacing: 8) {
                    Text("⬆️ 请从上方列表选择一个硬盘").font(.caption).foregroundColor(.orange)
                    Text("或点击「手动输入 UUID」").font(.caption).foregroundColor(.secondary)
                }.padding(.vertical, 10)
            }
            
            HStack {
                Button("取消", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: {
                    guard !uuid.isEmpty && !mountPoint.isEmpty else {
                        errorMessage = uuid.isEmpty ? "请选择硬盘或填写 UUID" : "请填写目标挂载点"
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
        .padding(30).frame(width: 500).onAppear { loadPhysicalDisks() }
    }
    
    func loadPhysicalDisks() {
        isLoading = true
        DispatchQueue.global().async {
            var disks: [PhysicalDisk] = []
            let task = Process()
            task.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
            task.arguments = ["list"]
            let pipe = Pipe()
            task.standardOutput = pipe
            
            defer {
                pipe.fileHandleForReading.closeFile()
            }
            
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                var currentDisk: String?
                var currentSize: String?
                
                for line in output.components(separatedBy: "\n") {
                    if line.contains("/dev/disk") && line.contains("external") {
                        let parts = line.components(separatedBy: " ")
                        if let device = parts.first { currentDisk = device }
                        if let sizeRange = line.range(of: "\\*?[\\d.]+\\s*[TGMB]B", options: .regularExpression) {
                            currentSize = String(line[sizeRange])
                        }
                    }
                    
                    if currentDisk != nil, (line.contains("Microsoft Basic Data") || line.contains("Apple_HFS")) {
                        let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                        if parts.count >= 5 {
                            let device = parts.last ?? ""
                            let volumeName = parts.dropFirst(3).dropLast(2).joined(separator: " ")
                            let size = parts.dropFirst(2).first ?? ""
                            
                            let uuidTask = Process()
                            uuidTask.executableURL = URL(fileURLWithPath: Constants.diskUtilPath)
                            uuidTask.arguments = ["info", device]
                            let uuidPipe = Pipe()
                            uuidTask.standardOutput = uuidPipe
                            
                            try? uuidTask.run()
                            uuidTask.waitUntilExit()
                            
                            let uuidData = uuidPipe.fileHandleForReading.readDataToEndOfFile()
                            let uuidOutput = String(data: uuidData, encoding: .utf8) ?? ""
                            
                            var volumeUUID = ""
                            var fileSystemType = ""
                            for uuidLine in uuidOutput.components(separatedBy: "\n") {
                                if uuidLine.contains("Volume UUID:") {
                                    let uuidParts = uuidLine.components(separatedBy: ":")
                                    if uuidParts.count == 2 { volumeUUID = uuidParts[1].trimmingCharacters(in: .whitespaces) }
                                }
                                if uuidLine.contains("File System Personality:") {
                                    let fsParts = uuidLine.components(separatedBy: ":")
                                    if fsParts.count == 2 { fileSystemType = fsParts[1].trimmingCharacters(in: .whitespaces) }
                                }
                            }
                            
                            if !volumeUUID.isEmpty && !fileSystemType.isEmpty {
                                let isAdded = addedUUIDs.contains(volumeUUID)
                                let currentMount = getCurrentMount(for: device)
                                disks.append(PhysicalDisk(device: device, uuid: volumeUUID, volumeName: volumeName, size: currentSize ?? size, isAdded: isAdded, currentMount: currentMount, fileSystemType: fileSystemType))
                            }
                        }
                    }
                    
                    if line.isEmpty { currentDisk = nil; currentSize = nil }
                }
            } catch {
                logger.error("扫描硬盘失败：\(error.localizedDescription)")
            }
            
            DispatchQueue.main.async { self.physicalDisks = disks; self.isLoading = false }
        }
    }
    
    func getCurrentMount(for device: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        task.standardOutput = pipe
        
        defer {
            pipe.fileHandleForReading.closeFile()
        }
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                if line.contains("/dev/\(device) ") {
                    let parts = line.components(separatedBy: " on ")
                    if parts.count >= 2 { return parts[1].split(separator: " ").first.map(String.init) }
                }
            }
        } catch { }
        return nil
    }
}
