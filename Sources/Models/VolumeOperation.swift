import Foundation

enum VolumeOperation: Equatable {
    case mount
    case unmount
    case remount
}

struct VolumeOperationResult: Equatable {
    let operation: VolumeOperation
    let commandSucceeded: Bool
    let commandMessage: String
    let queryState: VolumeQueryState
    var commandOutcome: CommandOutcome? = nil
    var authorizationDenied = false

    var success: Bool { commandSucceeded && queryState == .confirmed }
    var message: String {
        if case .unconfirmed(let reason) = queryState {
            return commandMessage + "；状态未确认：" + reason
        }
        return commandMessage
    }
}

enum BatchItemStatus: Equatable {
    case succeeded
    case failed
    case skipped
}

struct BatchVolumeResult: Equatable {
    let uuid: String
    let volumeName: String
    let status: BatchItemStatus
    let message: String
    let operationResult: VolumeOperationResult?
}

struct BatchOperationResult: Equatable {
    let operation: VolumeOperation
    let items: [BatchVolumeResult]
    var refreshError: String? = nil
    var rejectionReason: String? = nil

    var hasFailures: Bool { rejectionReason != nil || refreshError != nil || items.contains { $0.status == .failed } }
    var message: String {
        if let rejectionReason = rejectionReason { return rejectionReason }
        guard !items.isEmpty else { return refreshError ?? "没有可处理的卷配置" }
        let succeeded = items.filter { $0.status == .succeeded }.count
        let failed = items.filter { $0.status == .failed }.count
        let skipped = items.filter { $0.status == .skipped }.count
        var lines = ["批量完成：成功 \(succeeded)，失败 \(failed)，跳过 \(skipped)"]
        for item in items where item.status != .succeeded {
            let name = item.volumeName.isEmpty ? item.uuid : "\(item.volumeName)（\(item.uuid.prefix(8))）"
            lines.append("\(item.status == .failed ? "失败" : "跳过") · \(name)：\(item.message)")
        }
        if let refreshError = refreshError { lines.append("刷新失败：" + refreshError) }
        return lines.joined(separator: "\n")
    }
}
