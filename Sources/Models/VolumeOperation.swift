import Foundation

enum VolumeOperation: Equatable {
    case mount
    case unmount
    case remount

    func verificationFailure(actual: DiskInfo, targetMountPoint: String) -> String? {
        guard actual.isStateConfirmed else { return nil }
        switch self {
        case .unmount:
            return actual.isMounted ? "核实后卷仍处于挂载状态，卸载未完成" : nil
        case .mount, .remount:
            guard actual.isMounted else { return "核实后卷仍未挂载，挂载未完成" }
            guard !actual.currentMount.isEmpty,
                  let current = try? MountPoint.resolvedPath(actual.currentMount),
                  let target = try? MountPoint.resolvedPath(targetMountPoint), current == target else {
                return "核实后的实际挂载点与请求的目标不一致：\(actual.currentMount)"
            }
            return nil
        }
    }
}

struct VolumeOperationResult: Equatable {
    let operation: VolumeOperation
    let commandSucceeded: Bool
    let commandMessage: String
    let queryState: VolumeQueryState
    var commandOutcome: CommandOutcome? = nil
    var authorizationDenied = false
    var verificationFailure: String? = nil

    var success: Bool { commandSucceeded && queryState == .confirmed && verificationFailure == nil }
    var message: String {
        if let verificationFailure = verificationFailure {
            return "命令返回成功，但" + verificationFailure
        }
        if case .unconfirmed(let reason) = queryState {
            return (commandSucceeded ? "命令返回成功" : commandMessage) + "；状态未确认：" + reason
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
