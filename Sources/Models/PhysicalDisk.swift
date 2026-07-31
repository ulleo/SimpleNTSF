import Foundation

// MARK: - Physical Disk Model

struct PhysicalDisk: Identifiable, Codable {
    let id: UUID
    let device: String
    let uuid: String
    let volumeName: String
    let size: String
    var isAdded: Bool
    var currentMount: String?
    var fileSystemType: String?
    
    init(id: UUID = UUID(), device: String, uuid: String, volumeName: String, size: String, isAdded: Bool = false, currentMount: String? = nil, fileSystemType: String? = nil) {
        self.id = id
        self.device = device
        self.uuid = uuid
        self.volumeName = volumeName
        self.size = size
        self.isAdded = isAdded
        self.currentMount = currentMount
        self.fileSystemType = fileSystemType
    }
}
