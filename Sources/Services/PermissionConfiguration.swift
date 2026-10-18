import Foundation

/// Describes the app's dedicated sudoers configuration, not a guarantee that sudo will authorize execution.
enum PermissionConfiguration {
    enum Status: Equatable {
        case missing
        case unreadable
        case incomplete(missingCommands: [String])
        case configured

        var message: String {
            switch self {
            case .missing: return "尚未配置免密码权限"
            case .unreadable: return "无法读取权限配置，请重新配置"
            case .incomplete(let missing): return "权限配置缺少：" + missing.joined(separator: "、")
            case .configured: return "已配置权限"
            }
        }
    }

    enum GenerationError: LocalizedError {
        case unsupportedUsername
        var errorDescription: String? { "当前用户名不适用于权限配置；未修改用户名或请求授权" }
    }

    /// Kept beside the status checker so capability rules can share one source of truth.
    static func generatedContent(username: String) throws -> String {
        guard !username.isEmpty,
              username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw GenerationError.unsupportedUsername
        }
        return "\(username) ALL=(ALL) NOPASSWD: NOEXEC: \(Constants.mountNTFSPath), /sbin/mount, \(Constants.diskUtilPath)\n"
    }

    static func status(fileURL: URL = URL(fileURLWithPath: Constants.sudoersFilePath)) -> Status {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return .unreadable }
        return status(content: content)
    }

    static func status(content: String) -> Status {
        let required = [Constants.mountNTFSPath, "/sbin/mount", Constants.diskUtilPath]
        let commands = Set(content.components(separatedBy: .newlines).flatMap { line -> [String] in
            let entry = line.components(separatedBy: "#")[0]
            guard entry.contains("="), entry.contains("NOPASSWD:"),
                  let commandList = entry.components(separatedBy: ":").last else { return [] }
            return commandList.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        })
        let missing = required.filter { !commands.contains($0) }
        return missing.isEmpty ? .configured : .incomplete(missingCommands: missing)
    }
}
