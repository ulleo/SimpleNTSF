import Foundation
import Combine

/// Owns the administrator interaction and publishes a verified result on the main queue.
final class PermissionSetup: ObservableObject {
    enum Result: Equatable {
        case configured
        case cancelled
        case unconfirmed(String)
        case failed(String)

        var success: Bool { self == .configured }
        var message: String {
            switch self {
            case .configured: return "权限配置内容已核实；实际授权以命令执行结果为准。"
            case .unconfirmed(let message): return "配置结果未确认：" + message + "。安装可能已发生，请重新检查配置。"
            case .cancelled: return "已取消权限配置"
            case .failed(let message): return "配置失败：" + message
            }
        }
    }

    @Published private(set) var isConfiguring = false
    @Published private(set) var status: PermissionConfiguration.Status = .missing
    @Published private(set) var result: Result?
    private let username: String
    private let execute: CommandExecuting
    private let readStatus: () -> PermissionConfiguration.Status
    private let destination: String
    static let administratorTimeout: TimeInterval = 300

    init(username: String = NSUserName(), destination: String = Constants.sudoersFilePath,
         execute: @escaping CommandExecuting = { CommandRunner().run(executable: $0, arguments: $1, timeout: $2) },
         readStatus: (() -> PermissionConfiguration.Status)? = nil) {
        self.username = username
        self.destination = destination
        self.execute = execute
        self.readStatus = readStatus ?? { PermissionConfiguration.status(fileURL: URL(fileURLWithPath: destination), username: username) }
    }

    func refreshStatus() {
        precondition(Thread.isMainThread)
        guard !isConfiguring else { return }
        status = readStatus()
    }

    func configure(completion: ((Result) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard !isConfiguring else { return }
        let entry: String
        do { entry = try PermissionConfiguration.generatedContent(username: username) }
        catch {
            let failure = Result.failed(error.localizedDescription)
            result = failure
            completion?(failure)
            return
        }
        isConfiguring = true
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let shell = Self.installScript(content: entry, destination: self.destination)
            let command = self.execute("/usr/bin/osascript", ["-e", Self.authorizationScript, shell], Self.administratorTimeout)
            let cancelled = command.success && String(decoding: command.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == Self.cancellationMarker
            let status = command.success && !cancelled
                ? PermissionConfiguration.status(content: String(decoding: command.stdout, as: UTF8.self), username: self.username)
                : self.readStatus()
            let result: Result
            if cancelled { result = .cancelled }
            else if command.success { result = status == .configured ? .configured : .failed(status.message) }
            else {
                switch command.outcome {
                case .launchFailed, .exited: result = .failed(command.message)
                default: result = .unconfirmed(command.message)
                }
            }
            DispatchQueue.main.async {
                self.status = status
                self.result = result
                self.isConfiguring = false
                completion?(result)
            }
        }
    }

    private static let cancellationMarker = "SIMPLENTFS_AUTH_CANCELLED"
    private static let authorizationScript = """
    on run argv
        try
            return do shell script (item 1 of argv) with prompt "SimpleNTFS 需要管理员权限" with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then return "\(cancellationMarker)"
            error errorMessage number errorNumber
        end try
    end run
    """

    private static func installScript(content: String, destination: String) -> String {
        let directory = (destination as NSString).deletingLastPathComponent
        return """
        set -eu
        umask 077
        temp=$(/usr/bin/mktemp \(quote(directory + "/.simplentfs.XXXXXX")))
        trap '/bin/rm -f "$temp"' EXIT HUP INT TERM
        /usr/bin/printf '%s' \(quote(content)) > "$temp"
        /usr/sbin/visudo -cf "$temp" >/dev/null
        /usr/sbin/chown root:wheel "$temp"
        /bin/chmod 440 "$temp"
        /bin/mv -f "$temp" \(quote(destination))
        /bin/cat \(quote(destination))
        """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
