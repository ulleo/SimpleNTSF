import Foundation

enum VolumeQueryFailure: Error, Equatable {
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .timedOut: return "查询超时，请刷新重试"
        case .failed(let message): return message
        }
    }
}

enum VolumeQueryState: Codable, Equatable {
    case confirmed
    case unconfirmed(reason: String)
}

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
    var queryState: VolumeQueryState
    var hasConfirmedInformation: Bool

    var isStateConfirmed: Bool { queryState == .confirmed }
    var canMount: Bool { isStateConfirmed && !isMounted }
    var canUnmount: Bool { isStateConfirmed && isMounted }
    var statusMessage: String { isStateConfirmed ? (isMounted ? "已挂载" : "未挂载") : "状态未确认" }
    var queryFailureMessage: String? {
        if case .unconfirmed(let reason) = queryState { return reason }
        return nil
    }
    
    var id: String { uuid }

    var needsRemount: Bool {
        guard isStateConfirmed, isMounted, !currentMount.isEmpty, currentMount != "-" else { return false }
        guard let actual = try? MountPoint.resolvedPath(currentMount),
              let target = try? MountPoint.resolvedPath(mountPoint) else { return true }
        return actual != target
    }
    
    init(uuid: String, volumeName: String, mountPoint: String, device: String, currentMount: String, isMounted: Bool, usage: String? = nil, isTimeout: Bool = false, fileSystemType: String? = nil, queryState: VolumeQueryState = .confirmed, hasConfirmedInformation: Bool = true) {
        self.uuid = uuid
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.device = device
        self.currentMount = currentMount
        self.isMounted = isMounted
        self.usage = usage
        self.isTimeout = isTimeout
        self.fileSystemType = fileSystemType
        self.queryState = queryState
        self.hasConfirmedInformation = hasConfirmedInformation
    }
}
