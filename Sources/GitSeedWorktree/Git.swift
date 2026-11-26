import Darwin
import Foundation

struct Git {
    struct Exit: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32

        var description: String { "git \(arguments.joined(separator: " ")) exited \(status)" }
    }

    let directory: String
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func run(_ arguments: [String]) throws {
        _ = try invoke(arguments, capture: false)
    }

    func path(_ arguments: [String]) throws -> String {
        let bytes = try invoke(arguments, capture: true)
        guard bytes.last == 0x0A, let value = String(data: bytes.dropLast(), encoding: .utf8), !value.isEmpty else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }

    func independentWorktree(at path: String) throws -> Git {
        var independent = environment
        let keys = try invoke(["rev-parse", "--local-env-vars"], capture: true)
        for key in String(decoding: keys, as: UTF8.self).split(separator: "\n") {
            independent.removeValue(forKey: String(key))
        }
        return Git(directory: path, environment: independent)
    }

    func isIgnored(_ path: String) throws -> Bool {
        do {
            // A leading ./ avoids pathspec magic for names that start with a colon.
            // The trailing slash also matches rules that ignore directories only.
            try run(["check-ignore", "-q", "--", "./" + path + "/"])
        } catch let error as Exit where error.status == 1 {
            return false
        }
        return try invoke(["--literal-pathspecs", "ls-files", "-z", "--", path + "/"], capture: true).isEmpty
    }

    private func invoke(_ arguments: [String], capture: Bool) throws -> Data {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        child.arguments = ["-C", directory] + arguments
        child.environment = environment
        let output = capture ? Pipe() : nil
        if let output { child.standardOutput = output }
        try child.run()
        let bytes = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        child.waitUntilExit()
        let status = child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus
        guard status == 0 else { throw Exit(arguments: arguments, status: status) }
        return bytes
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
