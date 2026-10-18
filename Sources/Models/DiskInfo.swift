import Foundation

// MARK: - Disk Info Model

struct DiskInfo: Identifiable, Codable, Equatable {
    var uuid: String
    var volumeName: String
    var mountPoint: String
    var device: String
    var currentMount: String
    var isMounted: Bool
    var usage: String?
    var isTimeout: Bool = false
    var fileSystemType: String?
    
    var id: String { uuid }

    var needsRemount: Bool {
        guard isMounted, !currentMount.isEmpty, currentMount != "-" else { return false }
        guard let actual = try? MountPoint.resolvedPath(currentMount),
              let target = try? MountPoint.resolvedPath(mountPoint) else { return true }
        return actual != target
    }
    
    init(uuid: String, volumeName: String, mountPoint: String, device: String, currentMount: String, isMounted: Bool, usage: String? = nil, isTimeout: Bool = false, fileSystemType: String? = nil) {
        self.uuid = uuid
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.device = device
        self.currentMount = currentMount
        self.isMounted = isMounted
        self.usage = usage
        self.isTimeout = isTimeout
        self.fileSystemType = fileSystemType
    }
}
