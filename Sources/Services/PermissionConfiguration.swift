import Foundation

/// Checks only the explicit rules supported in the app's dedicated sudoers file.
/// This is not an effective-sudo-policy evaluator: runtime authorization remains separate.
enum PermissionConfiguration {
    enum Status: Equatable {
        case missing
        case unreadable
        case incomplete(missingCommands: [String])
        case unsupported
        case configured

        var message: String {
            switch self {
            case .missing: return "尚未配置免密码权限"
            case .unreadable: return "无法读取权限配置，请重新配置"
            case .incomplete(let missing): return "权限配置缺少或不兼容：" + missing.joined(separator: "、")
            case .unsupported: return "权限配置包含无法核实的规则，请重新配置"
            case .configured: return "配置内容符合预期"
            }
        }
    }

    enum GenerationError: LocalizedError {
        case unsupportedUsername
        var errorDescription: String? { "当前用户名不适用于权限配置；未修改用户名或请求授权" }
    }

    static func generatedContent(username: String) throws -> String {
        guard validUsername(username) else { throw GenerationError.unsupportedUsername }
        let commands = VolumeFileSystem.requiredPermissionCommands.joined(separator: ", ")
        // Both system mount and NTFS drivers may invoke helpers. Explicit EXEC overrides inherited NOEXEC.
        return "\(username) ALL=(ALL) NOPASSWD: EXEC: \(commands)\n"
    }

    static func status(fileURL: URL = URL(fileURLWithPath: Constants.sudoersFilePath), username: String = NSUserName()) -> Status {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return .unreadable }
        return status(content: content, username: username)
    }

    static func status(content: String, username: String = NSUserName()) -> Status {
        guard validUsername(username) else { return .unsupported }
        let required = VolumeFileSystem.requiredPermissionCommands
        var allowed: [String: Bool] = [:]
        let header = try! NSRegularExpression(pattern: "^([A-Za-z0-9_][A-Za-z0-9_.-]*)\\s+ALL\\s*=\\s*\\((ALL|root)\\)\\s+(.+)$")
        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") || trimmed.hasPrefix("@") || trimmed.range(of: "^#[0-9]", options: .regularExpression) != nil { return .unsupported }
            let line = trimmed.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard !line.contains("\\"), let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let userRange = Range(match.range(at: 1), in: line), let listRange = Range(match.range(at: 3), in: line) else { return .unsupported }
            // Explicit unrelated usernames do not apply; groups/aliases/Defaults are outside this subset.
            guard String(line[userRange]) != "ALL" else { return .unsupported }
            guard String(line[userRange]) == username else { continue }
            var passwordFree = false
            var allowsHelpers = true
            for rawItem in line[listRange].components(separatedBy: ",") {
                var item = rawItem.trimmingCharacters(in: .whitespaces)
                while let colon = item.firstIndex(of: ":") {
                    let tag = String(item[..<colon]).trimmingCharacters(in: .whitespaces)
                    switch tag {
                    case "NOPASSWD": passwordFree = true
                    case "PASSWD": passwordFree = false
                    case "EXEC": allowsHelpers = true
                    case "NOEXEC": allowsHelpers = false
                    default: return .unsupported
                    }
                    item = String(item[item.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                let denied = item.hasPrefix("!")
                if denied { item.removeFirst(); item = item.trimmingCharacters(in: .whitespaces) }
                let parts = item.split(whereSeparator: { $0.isWhitespace })
                guard let path = parts.first.map(String.init), path.hasPrefix("/"),
                      !item.contains(where: { "*?[]\\".contains($0) }) else { return .unsupported }
                if required.contains(path) {
                    // Arguments restrict a rule; they cannot satisfy all app operations.
                    allowed[path] = !denied && parts.count == 1 && passwordFree && allowsHelpers
                }
            }
        }
        let missing = required.filter { allowed[$0] != true }
        return missing.isEmpty ? .configured : .incomplete(missingCommands: missing)
    }

    /// Recognize explicit sudo diagnostics only. Exit code 1 also describes unrelated filesystem failures.
    static func isAuthorizationDenied(_ result: CommandResult) -> Bool {
        guard case .exited(let code) = result.outcome, code != 0 else { return false }
        let diagnostic = String(decoding: result.stderr, as: UTF8.self).lowercased()
        guard diagnostic.contains("sudo:") || diagnostic.hasPrefix("sorry, user ") else { return false }
        return ["a password is required", "not in the sudoers file", "not allowed to execute",
                "not allowed to run sudo", "may not run sudo", "a terminal is required to read the password"]
            .contains { diagnostic.contains($0) }
    }

    private static func validUsername(_ username: String) -> Bool {
        username != "ALL" && username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
}
