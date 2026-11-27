import Darwin
import Foundation

struct Git {
    struct Exit: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32

        var description: String { "git \(arguments.joined(separator: " ")) exited \(status)" }
    }

    let directory: String
    var environment: [String: String]
    private var indexedPaths: [Data]?

    init(directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory
        self.environment = environment
    }

    func run(_ arguments: [String], input: Data? = nil) throws {
        _ = try invoke(arguments, capture: false, input: input)
    }

    func capture(_ arguments: [String], input: Data? = nil) throws -> Data {
        try invoke(arguments, capture: true, input: input)
    }

    func path(_ arguments: [String], input: Data? = nil) throws -> String {
        let bytes = try invoke(arguments, capture: true, input: input)
        guard bytes.last == 0x0A, let value = String(data: bytes.dropLast(), encoding: .utf8), !value.isEmpty else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }

    func independentWorktree(at path: String) throws -> Git {
        var independent = environment
        let keys = try invoke(["rev-parse", "--local-env-vars"], capture: true)
        // Carry explicit Git configuration (including `git -c`) to both worktrees.
        for key in String(decoding: keys, as: UTF8.self).split(separator: "\n")
        where key != "GIT_CONFIG_PARAMETERS" && key != "GIT_CONFIG_COUNT" {
            independent.removeValue(forKey: String(key))
        }
        return Git(directory: path, environment: independent)
    }

    mutating func isIgnored(_ path: CachePath, caseSensitive: Bool) throws -> Bool {
        do {
            // A leading ./ avoids pathspec magic for names that start with a colon.
            // The trailing slash also matches rules that ignore directories only.
            try run(["check-ignore", "-q", "--", "./" + path.name + "/"])
        } catch let error as Exit where error.status == 1 {
            return false
        }
        let entries = try indexedPaths ?? invoke(["ls-files", "-z"], capture: true).split(separator: 0)
        indexedPaths = entries
        return !entries.contains { path.containsIndexedPath($0, caseSensitive: caseSensitive) }
    }

    func runHook(_ name: String, arguments: [String]) throws {
        // Execute hooks directly without GIT_DIR set (matching git worktree add),
        // so hooks that inspect other repositories or submodules are not redirected.
        let hookPath = try path(["rev-parse", "--git-path", "hooks/" + name])
        let resolved = hookPath.hasPrefix("/") ? hookPath : directory + "/" + hookPath
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(resolved, X_OK) == 0 else {
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: resolved)
        child.currentDirectoryURL = URL(fileURLWithPath: directory)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        let status = child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus
        guard status == 0 else { throw Exit(arguments: ["hook", "run", name] + arguments, status: status) }
    }

    private func invoke(_ arguments: [String], capture: Bool, input: Data? = nil) throws -> Data {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        child.arguments = ["-C", directory] + arguments
        child.environment = environment
        let output = capture ? Pipe() : nil
        if let output { child.standardOutput = output }
        let standardInput = try input.map(commandInput)
        defer { try? standardInput?.close() }
        if let standardInput { child.standardInput = standardInput }
        try child.run()
        let bytes = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        child.waitUntilExit()
        let status = child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus
        guard status == 0 else { throw Exit(arguments: arguments, status: status) }
        return bytes
    }

    private func commandInput(_ contents: Data) throws -> FileHandle {
        // An unlinked file lets Git read arbitrary path lists while it emits
        // output, without two pipes that could fill while waiting on each other.
        let path = FileManager.default.temporaryDirectory.appending(path: "git-seed-input-" + UUID().uuidString).path
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError("open Git input") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard unlink(path) == 0 else { throw FileError("unlink Git input") }
        try handle.write(contentsOf: contents)
        try handle.seek(toOffset: 0)
        return handle
    }
}

struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { throw FileError("stat \(path)") }
        device = info.st_dev
        inode = info.st_ino
    }
}
