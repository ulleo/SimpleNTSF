import Foundation

// MARK: - Discovered Volume Model

struct DiscoveredVolume: Identifiable, Codable {
    var id: String { uuid }
    let device: String
    let uuid: String
    let volumeName: String
    let size: String
    var isAdded: Bool
    var currentMount: String?
    var fileSystemType: String?
    
    init(device: String, uuid: String, volumeName: String, size: String, isAdded: Bool = false, currentMount: String? = nil, fileSystemType: String? = nil) {
        self.device = device
        self.uuid = uuid
        self.volumeName = volumeName
        self.size = size
        self.isAdded = isAdded
        self.currentMount = currentMount
        self.fileSystemType = fileSystemType
    }
}
