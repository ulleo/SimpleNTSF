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

    var success: Bool { commandSucceeded && queryState == .confirmed }
    var message: String {
        if case .unconfirmed(let reason) = queryState {
            return commandMessage + "；状态未确认：" + reason
        }
        return commandMessage
    }
}
