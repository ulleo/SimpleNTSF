import SwiftUI
import Foundation

// MARK: - Data Models

struct DiskInfo: Identifiable {
    let id = UUID()
    var uuid: String
    var mountPoint: String
    var device: String
    var currentMount: String
    var isMounted: Bool
}

struct PhysicalDisk: Identifiable {
    let id = UUID()
    let device: String
    let uuid: String
    let volumeName: String
    let size: String
    var isAdded: Bool = false
    var currentMount: String? = nil
}

// MARK: - Disk Manager

class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []
    
    var addedUUIDs: Set<String> {
        Set(disks.map { $0.uuid })
    }
    
    let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.SimpleNTFS"
        let configPath = "\(configDir)/ntfs-disks.conf"
        
        if !FileManager.default.fileExists(atPath: configDir) {
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        
        if !FileManager.default.fileExists(atPath: configPath) {
            let defaultContent = """
            # SimpleNTFS 配置文件
            # 格式：UUID:挂载点路径
            # 使用 diskutil info /dev/diskXsY | grep "Volume UUID" 获取 UUID
            
            """
            try? defaultContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        
        return configPath
    }()
    
    init() {
        loadConfig()
    }
    
    func loadConfig() {
        disks.removeAll()
        guard FileManager.default.fileExists(atPath: configPath) else { return }
        
        let content = try? String(contentsOfFile: configPath, encoding: .utf8)
        guard let lines = content?.components(separatedBy: "\n") else { return }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let uuid = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let mountPoint = String(parts[1]).trimmingCharacters(in: .whitespaces)
                let device = findDevice(byUUID: uuid)
                let isMounted = checkMounted(at: mountPoint)
                
                disks.append(DiskInfo(
                    uuid: uuid,
                    mountPoint: mountPoint,
                    device: device,
                    currentMount: isMounted ? mountPoint : "-",
                    isMounted: isMounted
                ))
            }
        }
    }
    
    func findDevice(byUUID uuid: String) -> String {
        let task = Process()
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["info", uuid]
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("Device Identifier:") {
                    let parts = line.split(separator: ":")
                    if parts.count == 2 {
                        return String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch { }
        return "未找到"
    }
    
    func checkMounted(at mountPoint: String) -> Bool {
        let task = Process()
        task.launchPath = "/sbin/mount"
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(" \(mountPoint) ")
        } catch { }
        return false
    }
    
    func mountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        let fm = FileManager.default
        if !fm.fileExists(atPath: mountPoint) {
            try? fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        }
        
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "/opt/homebrew/sbin/mount_ntfs", "/dev/" + device, mountPoint]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                return (true, "挂载成功！")
            } else {
                return (false, errorMessage.isEmpty ? "挂载失败" : errorMessage)
            }
        } catch {
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func unmountDisk(uuid: String, mountPoint: String) -> (success: Bool, message: String) {
        let device = findDevice(byUUID: uuid)
        guard device != "未找到" else { return (false, "未找到设备") }
        
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "/usr/sbin/diskutil", "unmountDisk", "force", "/dev/" + device]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                return (true, "卸载成功！")
            } else {
                return (false, errorMessage.isEmpty ? "卸载失败" : errorMessage)
            }
        } catch {
            return (false, "执行失败：\(error.localizedDescription)")
        }
    }
    
    func addDisk(uuid: String, mountPoint: String) -> Bool {
        var content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "\(uuid):\(mountPoint)\n"
        
        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
    
    func updateMountPoint(uuid: String, newMountPoint: String) -> Bool {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        var lines = content.components(separatedBy: "\n")
        
        for i in 0..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("\(uuid):") {
                lines[i] = "\(uuid):\(newMountPoint)"
                break
            }
        }
        
        content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
        
        do {
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
    
    func deleteDisk(uuid: String) -> Bool {
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
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = DiskManager()
    @State private var showingAddDialog = false
    @State private var newUUID = ""
    @State private var newMountPoint = ""
    @State private var alertMessage: String?
    @State private var alertIsError = false
    @State private var showingEditDialog = false
    @State private var editingDisk: DiskInfo?
    @State private var editMountPoint = ""
    @State private var showingDeleteConfirm = false
    @State private var deletingDisk: DiskInfo?
    @State private var showingUnmountConfirm = false
    @State private var unmountingDisk: DiskInfo?
    @State private var isConfiguring = false
    @State private var setupResult: String?
    @State private var setupSuccess = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with config button
            VStack(spacing: 8) {
                HStack {
                    Text("📀 SimpleNTFS")
                        .font(.title2.bold())
                    Spacer()
                    
                    if !isPasswordFree {
                        Button(action: configureSudoers) {
                            HStack {
                                Image(systemName: "lock.fill").foregroundColor(.orange)
                                Text("配置免密码权限").font(.caption)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.2)).cornerRadius(6)
                        }
                        .disabled(isConfiguring)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("权限已配置").font(.caption).foregroundColor(.green)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.green.opacity(0.2)).cornerRadius(6)
                    }
                }
                
                if let result = setupResult {
                    Text(result).font(.caption).foregroundColor(setupSuccess ? .green : .red)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill").foregroundColor(.blue)
                    Text("需要 macFUSE 支持").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.top).padding(.bottom, 10)
            
            Divider()
            
            // Disk list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($manager.disks) { $disk in
                        DiskRow(
                            disk: $disk,
                            onMount: {
                                let result = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                                alertMessage = result.message
                                alertIsError = !result.success
                                if result.success { manager.loadConfig() }
                            },
                            onUnmount: {
                                unmountingDisk = disk
                                showingUnmountConfirm = true
                            },
                            onEdit: {
                                editingDisk = disk
                                editMountPoint = disk.mountPoint
                                showingEditDialog = true
                            },
                            onDelete: {
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
            HStack {
                Button(action: { showingAddDialog = true }) {
                    Label("➕ 新增硬盘", systemImage: "plus")
                }
                Button(action: { manager.loadConfig() }) {
                    Label("🔄 刷新", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button(action: {
                    for disk in manager.disks {
                        _ = manager.mountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                    }
                    manager.loadConfig()
                }) {
                    Label("⬆️ 全部挂载", systemImage: "externaldrive.fill")
                }
                Button(action: {
                    for disk in manager.disks {
                        _ = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                    }
                    manager.loadConfig()
                }) {
                    Label("⬇️ 全部卸载", systemImage: "eject.fill")
                }
            }
            .padding()
        }
        .alert("提示", isPresented: .constant(alertMessage != nil)) {
            Button("确定", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
        .sheet(isPresented: $showingAddDialog) {
            AddDiskSheet(uuid: $newUUID, mountPoint: $newMountPoint, onSave: {
                let success = manager.addDisk(uuid: newUUID, mountPoint: newMountPoint)
                if success {
                    manager.loadConfig()
                    showingAddDialog = false
                    newUUID = ""
                    newMountPoint = ""
                } else {
                    alertMessage = "添加失败！"
                    alertIsError = true
                }
            }, onCancel: {
                showingAddDialog = false
                newUUID = ""
                newMountPoint = ""
            }, addedUUIDs: manager.addedUUIDs)
        }
        .sheet(isPresented: $showingEditDialog) {
            EditMountPointSheet(disk: editingDisk, mountPoint: $editMountPoint, onSave: {
                if let disk = editingDisk, !editMountPoint.isEmpty {
                    let success = manager.updateMountPoint(uuid: disk.uuid, newMountPoint: editMountPoint)
                    if success {
                        manager.loadConfig()
                        showingEditDialog = false
                        editingDisk = nil
                        editMountPoint = ""
                    }
                }
            }, onCancel: {
                showingEditDialog = false
                editingDisk = nil
                editMountPoint = ""
            })
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) { deletingDisk = nil }
            Button("删除", role: .destructive) {
                if let disk = deletingDisk {
                    let success = manager.deleteDisk(uuid: disk.uuid)
                    if success { manager.loadConfig() }
                    deletingDisk = nil
                }
            }
        } message: { Text("确定要从配置列表中删除此硬盘吗？") }
        .alert("确认卸载", isPresented: $showingUnmountConfirm) {
            Button("取消", role: .cancel) { unmountingDisk = nil }
            Button("卸载", role: .destructive) {
                if let disk = unmountingDisk {
                    DispatchQueue.global().async {
                        let result = manager.unmountDisk(uuid: disk.uuid, mountPoint: disk.mountPoint)
                        DispatchQueue.main.async {
                            if result.success { manager.loadConfig() }
                            else { alertMessage = result.message; alertIsError = true }
                            unmountingDisk = nil
                        }
                    }
                }
            }
        } message: { Text("确定要卸载此硬盘吗？") }
    }
    
    var isPasswordFree: Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", "true"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }
    
    func configureSudoers() {
        isConfiguring = true
        setupResult = "正在配置..."
        
        let sudoersEntry = "%admin ALL=(ALL) NOPASSWD: /opt/homebrew/sbin/mount_ntfs, /usr/sbin/diskutil"
        let sudoersFile = "/etc/sudoers.d/simplentfs"
        let script = "echo '" + sudoersEntry + "' > /tmp/simplentfs_sudoers && sudo mv /tmp/simplentfs_sudoers " + sudoersFile + " && sudo chmod 440 " + sudoersFile
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "do shell script \"" + script + "\" with prompt \"SimpleNTFS 需要管理员权限\" with administrator privileges"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        DispatchQueue.global().async {
            do {
                try task.run()
                task.waitUntilExit()
                
                DispatchQueue.main.async {
                    isConfiguring = false
                    if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: sudoersFile) {
                        setupSuccess = true
                        setupResult = "✅ 配置成功！现在挂载/卸载无需密码。"
                    } else {
                        setupSuccess = false
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        setupResult = "❌ 配置失败：" + (String(data: errorData, encoding: .utf8) ?? "未知错误")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isConfiguring = false
                    setupSuccess = false
                    setupResult = "❌ 配置失败：" + error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Disk Row

struct DiskRow: View {
    @Binding var disk: DiskInfo
    let onMount: () -> Void
    let onUnmount: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device).font(.system(.body, design: .monospaced))
                    Text(disk.isMounted ? "✅ 已挂载" : "⭕ 未挂载")
                        .font(.caption).foregroundColor(disk.isMounted ? .green : .orange)
                }
                Text("UUID: " + String(disk.uuid.prefix(8)) + "...").font(.caption).foregroundColor(.secondary)
            }
            .frame(width: 280, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("当前：" + disk.currentMount).font(.system(.body, design: .monospaced))
                Text("目标：" + disk.mountPoint).font(.caption).foregroundColor(.secondary)
            }
            .frame(width: 250, alignment: .leading)
            
            Spacer()
            
            HStack(spacing: 6) {
                Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.bordered).tint(.blue)
                if disk.isMounted {
                    Button("卸载", action: onUnmount).buttonStyle(.bordered).tint(.orange)
                } else {
                    Button("挂载", action: onMount).buttonStyle(.bordered).tint(.green)
                }
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.bordered).tint(.red)
            }
            .frame(width: 160, alignment: .center)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: 8).fill(disk.isMounted ? Color.green.opacity(0.05) : Color.clear)))
    }
}

// MARK: - Add Disk Sheet

struct AddDiskSheet: View {
    @Binding var uuid: String
    @Binding var mountPoint: String
    let onSave: () -> Void
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
            Text("➕ 新增 NTFS 硬盘").font(.title2.bold())
            
            if isLoading {
                ProgressView("正在扫描硬盘...").padding()
            } else if physicalDisks.isEmpty {
                VStack(spacing: 10) {
                    Text("⚠️ 未检测到 NTFS 硬盘").foregroundColor(.orange)
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
                    onSave()
                    onCancel()
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
            task.launchPath = "/usr/sbin/diskutil"
            task.arguments = ["list"]
            let pipe = Pipe()
            task.standardOutput = pipe
            
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
                    
                    if currentDisk != nil, line.contains("Microsoft Basic Data") {
                        let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                        if parts.count >= 5 {
                            let device = parts.last ?? ""
                            let volumeName = parts.dropFirst(3).dropLast(2).joined(separator: " ")
                            let size = parts.dropFirst(2).first ?? ""
                            
                            let uuidTask = Process()
                            uuidTask.launchPath = "/usr/sbin/diskutil"
                            uuidTask.arguments = ["info", device]
                            let uuidPipe = Pipe()
                            uuidTask.standardOutput = uuidPipe
                            
                            try? uuidTask.run()
                            uuidTask.waitUntilExit()
                            
                            let uuidData = uuidPipe.fileHandleForReading.readDataToEndOfFile()
                            let uuidOutput = String(data: uuidData, encoding: .utf8) ?? ""
                            
                            var volumeUUID = ""
                            for uuidLine in uuidOutput.components(separatedBy: "\n") {
                                if uuidLine.contains("Volume UUID:") {
                                    let uuidParts = uuidLine.components(separatedBy: ":")
                                    if uuidParts.count == 2 { volumeUUID = uuidParts[1].trimmingCharacters(in: .whitespaces) }
                                }
                            }
                            
                            if !volumeUUID.isEmpty {
                                let isAdded = addedUUIDs.contains(volumeUUID)
                                let currentMount = getCurrentMount(for: device)
                                disks.append(PhysicalDisk(device: device, uuid: volumeUUID, volumeName: volumeName, size: currentSize ?? size, isAdded: isAdded, currentMount: currentMount))
                            }
                        }
                    }
                    
                    if line.isEmpty { currentDisk = nil; currentSize = nil }
                }
            } catch { }
            
            DispatchQueue.main.async { self.physicalDisks = disks; self.isLoading = false }
        }
    }
    
    func getCurrentMount(for device: String) -> String? {
        let task = Process()
        task.launchPath = "/sbin/mount"
        let pipe = Pipe()
        task.standardOutput = pipe
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

// MARK: - Disk List Item

struct DiskListItem: View {
    let disk: PhysicalDisk
    let isSelected: Bool
    let onSelect: (String) -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(disk.device + " - " + disk.volumeName).font(.system(.body, design: .monospaced))
                    if disk.isAdded { Text("✅ 已添加").font(.caption).foregroundColor(.green) }
                }
                Text("UUID: " + disk.uuid).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(disk.size).font(.caption).foregroundColor(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(disk.isAdded ? Color.green : (isSelected ? Color.blue : Color.gray), lineWidth: 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(disk.isAdded ? Color.green.opacity(0.05) : (isSelected ? Color.blue.opacity(0.1) : Color.clear))))
        .opacity(disk.isAdded ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(disk.currentMount ?? "") }
    }
}

// MARK: - Edit Mount Point Sheet

struct EditMountPointSheet: View {
    let disk: DiskInfo?
    @Binding var mountPoint: String
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("✏️ 修改挂载点").font(.title2.bold())
            if let disk = disk {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("硬盘：").font(.caption).foregroundColor(.secondary)
                        Text(disk.device + " - " + String(disk.uuid.prefix(8)) + "...").font(.system(.body, design: .monospaced))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前状态：").font(.caption).foregroundColor(.secondary)
                        Text(disk.isMounted ? "✅ 已挂载" : "⭕ 未挂载")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(disk.isMounted ? .green : .orange)
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
                Button("保存", action: onSave).buttonStyle(.borderedProminent).disabled(mountPoint.isEmpty)
            }
        }.padding(30).frame(minWidth: 500, minHeight: 300)
    }
}
