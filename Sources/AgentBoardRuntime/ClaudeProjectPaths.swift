import Foundation

public enum MemoryLinkResult: Sendable, Equatable {
    case linked
    case alreadyLinked
    case relinked(previousTarget: String)
    case replacedEmptyDirectory
    case leftInPlace(reason: String)
}

public enum ClaudeProjectPaths {
    public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Claude Code's project slug: every `/` and `.` in the absolute path becomes `-`.
    public static func slug(forPath path: String) -> String {
        String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    public static func projectDir(forPath path: String, projectsRoot: URL = defaultProjectsRoot) -> URL {
        projectsRoot.appendingPathComponent(slug(forPath: path))
    }

    public static func memoryDir(forPath path: String, projectsRoot: URL = defaultProjectsRoot) -> URL {
        projectDir(forPath: path, projectsRoot: projectsRoot).appendingPathComponent("memory")
    }

    public static func linkMemory(
        worktreePath: String,
        to canonicalMemoryDir: URL,
        projectsRoot: URL = defaultProjectsRoot
    ) throws -> MemoryLinkResult {
        let fm = FileManager.default
        let projectDir = projectDir(forPath: worktreePath, projectsRoot: projectsRoot)
        let memory = memoryDir(forPath: worktreePath, projectsRoot: projectsRoot)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalMemoryDir, withIntermediateDirectories: true)

        let targetPath = canonicalPath(canonicalMemoryDir)

        if let attrs = try? fm.attributesOfItem(atPath: memory.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            let destination = try fm.destinationOfSymbolicLink(atPath: memory.path)
            let resolved = canonicalPath(URL(fileURLWithPath: destination, relativeTo: projectDir))
            if resolved == targetPath { return .alreadyLinked }
            try fm.removeItem(at: memory)
            try fm.createSymbolicLink(at: memory, withDestinationURL: canonicalMemoryDir)
            return .relinked(previousTarget: destination)
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: memory.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                return .leftInPlace(reason: "\(memory.path) exists and is not a directory")
            }
            let contents = try fm.contentsOfDirectory(atPath: memory.path)
            guard contents.isEmpty else {
                return .leftInPlace(reason: "\(memory.path) is a non-empty directory (\(contents.count) entries)")
            }
            try fm.removeItem(at: memory)
            try fm.createSymbolicLink(at: memory, withDestinationURL: canonicalMemoryDir)
            return .replacedEmptyDirectory
        }

        try fm.createSymbolicLink(at: memory, withDestinationURL: canonicalMemoryDir)
        return .linked
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
