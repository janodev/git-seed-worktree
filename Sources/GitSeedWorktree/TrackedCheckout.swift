import CryptoKit
import Darwin
import Foundation

enum TrackedCheckoutOutcome: Equatable {
    case finished(cloned: Int, checkedOut: Int)
    case standard(String)
}

struct TrackedCheckoutFailure: Error, CustomStringConvertible {
    let path: String
    let cause: any Error

    var description: String { "Checkout did not finish in \(path): \(cause)" }
}

struct TrackedCheckout {
    let donor: Git
    let destination: Git
    let caseSensitive: Bool

    private func standardCheckoutReason() throws -> String? {
        let config: Data
        do {
            config = try destination.capture(["config", "--null", "--get-regexp",
                "^(core\\.sparsecheckout|core\\.autocrlf|submodule\\.recurse)$"])
        } catch let error as Git.Exit where error.status == 1 {
            return nil
        }
        guard config.last == 0 else { throw MalformedGitOutput(command: "config") }
        var effective = [String: String]()
        for field in config.split(separator: 0) {
            let entry = String(decoding: field, as: UTF8.self).split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
            )
            guard let key = entry.first else { throw MalformedGitOutput(command: "config") }
            effective[String(key)] = entry.count == 2 ? entry[1].lowercased() : "true"
        }
        for key in ["core.sparsecheckout", "core.autocrlf", "submodule.recurse"] {
            if let value = effective[key], !["", "false", "no", "off", "0"].contains(value) {
                return "\(key) uses Git's standard checkout"
            }
        }
        return nil
    }

    static func hasDonorCommit(_ donor: Git) throws -> Bool {
        do {
            _ = try donor.capture(["rev-parse", "--verify", "-q", "HEAD^{commit}"])
            return true
        } catch let error as Git.Exit where error.status == 1 {
            return false
        }
    }

    func finish() throws -> TrackedCheckoutOutcome {
        do {
            return try materialize()
        } catch {
            throw TrackedCheckoutFailure(path: destination.directory, cause: error)
        }
    }

    private func materialize() throws -> TrackedCheckoutOutcome {
        // Read config after Git has copied config.worktree and assigned the new
        // gitdir and branch, so conditional includes see the actual destination.
        if let reason = try standardCheckoutReason() {
            // This is the initial checkout command used by Git's worktree add.
            try destination.run(["reset", "--hard", "--no-recurse-submodules"])
            return .standard(reason)
        }
        let head = try destination.path(["rev-parse", "--verify", "HEAD"])
        try destination.run(["read-tree", head])
        let entries = try tree(in: destination, commit: head)
        let source = try Directory(path: donor.directory)
        let target = try Directory(path: destination.directory)
        let cloned = try cloneEntries(entries, source: source, target: target)
        let remaining = entries.filter { !cloned.contains($0.path) }
        if !remaining.isEmpty {
            try destination.run(["checkout-index", "-f", "--index", "-z", "--stdin"],
                                input: pathList(remaining))
        }
        do {
            try destination.run(["update-index", "-q", "--refresh"])
        } catch let error as Git.Exit where error.status == 1 {
            // Matching entries were still refreshed; mismatched paths (e.g. collisions) are normal.
        }
        return .finished(cloned: cloned.count, checkedOut: remaining.count)
    }

    private func cloneEntries(_ entries: [TreeEntry], source: Directory, target: Directory) throws -> Set<Data> {
        let device = try source.status().st_dev
        guard try target.status().st_dev == device else { return [] }

        let sourceEntries = try tree(in: donor, commit: "HEAD")
        let sourceByPath = Dictionary(uniqueKeysWithValues: sourceEntries.map { ($0.path, $0) })
        let colliding = collidingPaths(entries)
        let candidates = entries.filter {
            $0.regular && !colliding.contains($0.path) && sourceByPath[$0.path] == $0
        }
        guard !candidates.isEmpty else { return [] }
        let transformed = try pathsWithCheckoutConversion(candidates)

        let stagingName = ".git-seed-worktree-" + UUID().uuidString
        try target.make(stagingName)
        defer { _ = unlinkat(target.fd, stagingName, AT_REMOVEDIR) }
        let staging = try target.open(stagingName)
        var cloned = Set<Data>()
        for entry in candidates where !transformed.contains(entry.path) {
            switch try cloneEntry(entry, from: source, to: target, staging: staging, device: device) {
            case .cloned:
                cloned.insert(entry.path)
            case .fallback:
                break
            case .unsupportedVolume:
                return cloned
            }
        }
        return cloned
    }

    private func collidingPaths(_ entries: [TreeEntry]) -> Set<Data> {
        var fileOwners = [[String]: [Data]]()
        var directoryPrefixes = Set<[String]>()
        var normalized = [(Data, [String])]()
        normalized.reserveCapacity(entries.count)
        for entry in entries {
            guard let name = String(data: entry.path, encoding: .utf8),
                  let components = worktreePathComponents(name) else { continue }
            let key = caseSensitive ? components : components.map(CachePath.comparisonKey)
            normalized.append((entry.path, key))
            fileOwners[key, default: []].append(entry.path)
            for depth in 1..<key.count {
                directoryPrefixes.insert(Array(key.prefix(depth)))
            }
        }
        var result = Set<Data>()
        for (path, key) in normalized {
            if (fileOwners[key]?.count ?? 0) > 1 || directoryPrefixes.contains(key) {
                result.insert(path)
                continue
            }
            for depth in 1..<key.count where fileOwners[Array(key.prefix(depth))] != nil {
                result.insert(path)
                break
            }
        }
        return result
    }

    private func tree(in git: Git, commit: String) throws -> [TreeEntry] {
        try git.capture(["ls-tree", "-r", "-z", commit]).split(separator: 0).map(TreeEntry.init)
    }

    private func pathsWithCheckoutConversion(_ candidates: [TreeEntry]) throws -> Set<Data> {
        // Omit --cached so attr.tree and GIT_ATTR_SOURCE are honored; when neither
        // is set, Git falls back to the index while the worktree is still empty.
        let output = try destination.capture(["check-attr", "--all", "-z", "--stdin"],
                                             input: pathList(candidates))
        guard output.isEmpty || output.last == 0 else { throw MalformedGitOutput(command: "check-attr") }
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count.isMultiple(of: 3) else { throw MalformedGitOutput(command: "check-attr") }
        var result = Set<Data>()
        for i in stride(from: 0, to: fields.count, by: 3) {
            let attribute = String(decoding: fields[i + 1], as: UTF8.self)
            let value = String(decoding: fields[i + 2], as: UTF8.self)
            // The binary macro emits -text, which admits byte-for-byte clones.
            // Explicit filter names can spell "unset", so let Git handle them.
            switch attribute {
            case "text" where value != "unset", "crlf", "eol", "ident", "filter", "working-tree-encoding":
                result.insert(fields[i])
            default:
                break
            }
        }
        return result
    }

    private enum CloneAttempt {
        case cloned
        case fallback
        case unsupportedVolume
    }

    private func cloneEntry(_ entry: TreeEntry, from source: Directory, to target: Directory,
                            staging: Directory, device: dev_t) throws -> CloneAttempt {
        guard let name = String(data: entry.path, encoding: .utf8),
              let components = worktreePathComponents(name), let leaf = components.last,
              let parent = try? components.dropLast().reduce(source, { try $0.open($1) }) else { return .fallback }
        let fd = openat(parent.fd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .fallback }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == device,
              info.st_flags == 0, hasOnlyCheckoutAttributes(fd) else { return .fallback }
        do {
            try staging.clone(fd, as: "file", diagnosticPath: name)
        } catch let error as FileError where error.code == ENOTSUP || error.code == EXDEV {
            return .unsupportedVolume
        } catch is FileError {
            // Git can still write this entry from its object database.
            return .fallback
        }
        defer { _ = unlinkat(staging.fd, "file", 0) }
        let staged = openat(staging.fd, "file", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard staged >= 0 else { throw FileError("open staged file \(name)") }
        let handle = FileHandle(fileDescriptor: staged, closeOnDealloc: true)
        guard fstat(staged, &info) == 0 else { throw FileError("inspect staged file \(name)") }
        if info.st_flags != 0 {
            _ = fchflags(staged, 0)
            return .fallback
        }
        guard hasOnlyCheckoutAttributes(staged) else { return .fallback }
        guard try entry.matches(handle, size: info.st_size) else { return .fallback }

        let permissions: mode_t = entry.mode == "100755" ? 0o777 : 0o666
        guard fchmod(staged, permissions & ~getumask()) == 0 else { throw FileError("set mode of \(name)") }
        let destinationParent: Directory
        do {
            destinationParent = try components.dropLast().reduce(target) { try $0.openOrMake($1, mode: 0o777) }
        } catch let error as FileError where error.code == ENOTDIR || error.code == ELOOP {
            return .fallback
        }
        guard renameatx_np(staging.fd, "file", destinationParent.fd, leaf, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return .fallback }
            throw FileError("publish tracked file \(name)")
        }
        return .cloned
    }

    private func hasOnlyCheckoutAttributes(_ file: Int32) -> Bool {
        // macOS attaches provenance to files written by the installed Git.
        // Other extended attributes may have come from the user's checkout.
        let provenance = "com.apple.provenance\0".utf8
        var names = [UInt8](repeating: 0, count: provenance.count)
        let count = flistxattr(file, &names, names.count, 0)
        return count == 0 || (count == names.count && names.elementsEqual(provenance))
    }

    private func pathList(_ entries: [TreeEntry]) -> Data {
        var result = Data()
        for entry in entries {
            result.append(entry.path)
            result.append(0)
        }
        return result
    }
}

private struct TreeEntry: Equatable {
    let path: Data
    let mode: String
    let object: String

    var regular: Bool { mode == "100644" || mode == "100755" }

    init(_ record: Data) throws {
        guard let separator = record.firstIndex(of: 0x09) else { throw MalformedGitOutput(command: "ls-tree") }
        let metadata = String(decoding: record[..<separator], as: UTF8.self).split(separator: " ")
        guard metadata.count == 3 else { throw MalformedGitOutput(command: "ls-tree") }
        mode = String(metadata[0])
        object = String(metadata[2])
        path = Data(record[record.index(after: separator)...])
    }

    func matches(_ handle: FileHandle, size: Int64) throws -> Bool {
        switch object.utf8.count {
        case 40: try matches(handle, size: size, using: Insecure.SHA1.self)
        case 64: try matches(handle, size: size, using: SHA256.self)
        default: throw MalformedGitOutput(command: "ls-tree")
        }
    }

    private func matches<H: HashFunction>(_ handle: FileHandle, size: Int64, using _: H.Type) throws -> Bool {
        var hash = H()
        hash.update(data: Data("blob \(size)\0".utf8))
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        let hex = Array("0123456789abcdef".utf8)
        return hash.finalize().flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }.elementsEqual(object.utf8)
    }
}

private struct MalformedGitOutput: Error, CustomStringConvertible {
    let command: String
    var description: String { "Unexpected output from git \(command)" }
}
