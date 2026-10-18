import Foundation

/// The same path rules apply to saved configuration, editing and mounting.
enum MountPoint {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func resolvedPath(_ path: String) throws -> String {
        try resolve((path as NSString).expandingTildeInPath, depth: 0)
    }

    // Resolve each existing ancestor before appending nonexistent children. Foundation's
    // resolvingSymlinksInPath alone leaves symlinks unresolved when the final path is absent.
    private static func resolve(_ path: String, depth: Int) throws -> String {
        guard depth < 40 else { throw Invalid(message: "挂载点包含循环符号链接") }
        var result = URL(fileURLWithPath: "/")
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { result.deleteLastPathComponent(); continue }
            let parent = result
            result.appendPathComponent(String(part))
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: result.path) {
                let target = destination.hasPrefix("/") ? destination : parent.path + "/" + destination
                result = URL(fileURLWithPath: try resolve(target, depth: depth + 1))
            }
        }
        return result.path
    }

    static func normalize(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw Invalid(message: "请填写有效的目标挂载点，不能包含换行或空字符")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Invalid(message: "挂载点必须为绝对路径或 ~/ 开头的路径") }
        let resolved = try resolvedPath(path)
        for prefix in Constants.forbiddenMountPrefixes {
            if contains(resolved, in: try resolvedPath(prefix)) {
                throw Invalid(message: "不允许挂载到系统目录：\(prefix)")
            }
        }
        let home = try resolvedPath(FileManager.default.homeDirectoryForCurrentUser.path)
        guard contains(resolved, in: home) else {
            throw Invalid(message: "挂载点必须位于用户目录下：\(home)")
        }
        var ancestor = URL(fileURLWithPath: resolved)
        while ancestor.path != "/" {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &directory) {
                guard directory.boolValue else { throw Invalid(message: "挂载点或其父路径已存在但不是目录") }
                break
            }
            ancestor.deleteLastPathComponent()
        }
        return resolved
    }

    private static func contains(_ path: String, in directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }
}
