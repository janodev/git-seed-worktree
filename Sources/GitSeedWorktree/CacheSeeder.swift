import Darwin
import Foundation

enum CacheOutcome: Equatable {
    case cloned
    case skipped(String)
    case failed(String)

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct CacheSeeder {
    private static let blockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    let donor: String
    let destination: String

    func transfer(_ path: CachePath, ifEligible: () throws -> Bool) -> CacheOutcome {
        do {
            return try clone(path, ifEligible: ifEligible)
        } catch let error as FileError where error.code == ENOTSUP || error.code == EXDEV {
            return .skipped("the source and destination cannot share disk blocks")
        } catch let error as IneligibleCache {
            return .skipped(error.reason)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func clone(_ path: CachePath, ifEligible: () throws -> Bool) throws -> CacheOutcome {
        let donorRoot = try Directory(path: donor)
        let destinationRoot = try Directory(path: destination)

        // Check physical paths before asking Git about the checkout. Git rejects
        // an ignore query that crosses a symlink, including one made by a hook.
        if let parent = try destinationRoot.cacheParent(for: path), try parent.contains(path.leaf) {
            return .skipped("the destination already exists")
        }
        let source: Directory
        do {
            source = try path.components.reduce(donorRoot) { parent, name in try parent.open(name) }
        } catch let error as FileError where error.code == ENOENT {
            return .skipped("the seed directory is absent")
        } catch let error as FileError where error.code == ENOTDIR || error.code == ELOOP {
            return .skipped("the seed path must contain real directories")
        }
        guard try ifEligible() else { return .skipped("the cache path must be ignored in both worktrees") }

        let device = try source.status().st_dev
        guard try donorRoot.status().st_dev == device, try destinationRoot.status().st_dev == device else {
            throw FileError("clone across volumes", code: EXDEV)
        }

        // Keep incomplete copies out of the final cache path. The exclusive
        // rename also protects files created by a post-checkout hook.
        let stagingName = ".git-seed-worktree-" + UUID().uuidString
        try destinationRoot.make(stagingName)
        let stagingPath = destination + "/" + stagingName
        defer { try? FileManager.default.removeItem(atPath: stagingPath) }
        let staging = try destinationRoot.open(stagingName)
        try staging.make("cache", mode: 0o777)
        let stagedCache = try staging.open("cache")
        var links = [String]()
        try cloneContents(source, into: stagedCache, device: device, prefix: "", links: &links)
        for link in links {
            var status = stat()
            guard fstatat(stagedCache.fd, link, &status, AT_RESOLVE_BENEATH) == 0 else {
                throw IneligibleCache("symlink \(link) must resolve inside the cache")
            }
        }

        let parent: Directory
        do {
            parent = try path.components.dropLast().reduce(destinationRoot) { parent, name in
                try parent.openOrMake(name, mode: 0o777)
            }
        } catch let error as FileError where error.code == ENOTDIR || error.code == ELOOP {
            return .skipped("the destination parent must contain real directories")
        }
        guard renameatx_np(staging.fd, "cache", parent.fd, path.leaf, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return .skipped("the destination already exists") }
            throw FileError("publish cache \(path.name)")
        }
        return .cloned
    }

    private func cloneContents(_ source: Directory, into target: Directory, device: dev_t, prefix: String,
                               links: inout [String]) throws {
        for name in try source.names() {
            let path = prefix + name
            guard name.lowercased() != ".git" else { throw IneligibleCache("Git metadata at \(path)") }
            var status = stat()
            guard fstatat(source.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FileError("inspect \(path)")
            }
            guard status.st_dev == device else { throw IneligibleCache("mount point at \(path)") }
            guard status.st_flags & Self.blockingFlags == 0 else { throw IneligibleCache("locked item at \(path)") }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let child = try source.open(name)
                let childStatus = try child.status()
                guard childStatus.st_dev == device else { throw IneligibleCache("mount point at \(path)") }
                guard childStatus.st_flags & Self.blockingFlags == 0 else {
                    throw IneligibleCache("locked item at \(path)")
                }
                try target.make(name, mode: 0o777)
                try cloneContents(child, into: target.open(name), device: device,
                                  prefix: path + "/", links: &links)
            case S_IFREG:
                try cloneFile(name, from: source, into: target, device: device, path: path)
            case S_IFLNK:
                var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = readlinkat(source.fd, name, &bytes, bytes.count)
                guard count >= 0 else { throw FileError("read symlink \(path)") }
                guard count < bytes.count, let link = String(bytes: bytes.prefix(count), encoding: .utf8),
                      !link.hasPrefix("/") else { throw IneligibleCache("unsupported symlink at \(path)") }
                guard symlinkat(link, target.fd, name) == 0 else { throw FileError("clone symlink \(path)") }
                links.append(path)
            default:
                throw IneligibleCache("unsupported filesystem entry at \(path)")
            }
        }
    }

    private func cloneFile(_ name: String, from source: Directory, into target: Directory, device: dev_t,
                           path: String) throws {
        let file = openat(source.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw FileError("open \(path)") }
        defer { _ = close(file) }
        var status = stat()
        guard fstat(file, &status) == 0 else { throw FileError("inspect \(path)") }
        guard status.st_dev == device else { throw IneligibleCache("mount point at \(path)") }
        guard status.st_flags & Self.blockingFlags == 0 else { throw IneligibleCache("locked item at \(path)") }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw IneligibleCache("unsupported filesystem entry at \(path)")
        }
        try target.clone(file, as: name, diagnosticPath: path)
    }
}

private struct IneligibleCache: Error {
    let reason: String

    init(_ reason: String) { self.reason = reason }
}

struct FileError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

final class Directory {
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    let fd: Int32

    init(path: String) throws {
        fd = Darwin.open(path, Self.openFlags)
        guard fd >= 0 else { throw FileError("open directory \(path)") }
    }

    private init(fd: Int32) { self.fd = fd }

    deinit { _ = close(fd) }

    func open(_ name: String) throws -> Directory {
        let child = openat(fd, name, Self.openFlags)
        guard child >= 0 else { throw FileError("open directory \(name)") }
        return Directory(fd: child)
    }

    func make(_ name: String, mode: mode_t = 0o700) throws {
        guard mkdirat(fd, name, mode) == 0 else { throw FileError("create directory \(name)") }
    }

    func openOrMake(_ name: String, mode: mode_t = 0o700) throws -> Directory {
        do {
            return try open(name)
        } catch let error as FileError where error.code == ENOENT {
            guard mkdirat(fd, name, mode) == 0 || errno == EEXIST else {
                throw FileError("create directory \(name)")
            }
            return try open(name)
        }
    }

    func clone(_ sourceFile: Int32, as name: String, diagnosticPath: String) throws {
        guard fclonefileat(sourceFile, fd, name, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
            throw FileError("clone \(diagnosticPath)")
        }
    }

    func cacheParent(for path: CachePath) throws -> Directory? {
        do {
            return try path.components.dropLast().reduce(self) { parent, name in try parent.open(name) }
        } catch let error as FileError where error.code == ENOENT {
            return nil
        } catch let error as FileError where error.code == ENOTDIR || error.code == ELOOP {
            throw IneligibleCache("the destination parent must contain real directories")
        }
    }

    func contains(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw FileError("inspect destination \(name)") }
        return false
    }

    func status() throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FileError("inspect directory") }
        return info
    }

    func names() throws -> [String] {
        let scan = openat(fd, ".", Self.openFlags)
        guard scan >= 0 else { throw FileError("open directory for listing") }
        guard let stream = fdopendir(scan) else {
            let error = FileError("read directory")
            _ = close(scan)
            throw error
        }
        defer { _ = closedir(stream) }
        var names = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FileError("read directory entry") }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { throw IneligibleCache("non-UTF-8 filename") }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}
