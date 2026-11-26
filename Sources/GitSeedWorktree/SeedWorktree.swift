import ArgumentParser
import Foundation

@main
struct SeedWorktree: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git-seed-worktree",
        abstract: "Create a Git worktree and clone selected caches from another checkout."
    )

    @Option(name: [.customShort("b"), .long], help: "Create a branch at the selected commit.")
    var branch: String?

    @Argument(help: "Path for the new worktree.")
    var path: String

    @Argument(help: "Branch, tag, or commit to pass to git worktree add.")
    var start: String?

    @Option(help: "Root of a finished checkout of the same repository.")
    var seed: String

    @Option(parsing: .singleValue, help: "Ignored cache directory relative to each worktree. Repeat to seed several.")
    var cache: [String] = []

    func run() throws {
        let git = Git(directory: FileManager.default.currentDirectoryPath)
        do {
            let result = try create(using: git)
            print("Worktree: \(result.path)")
            for (cache, outcome) in result.caches {
                switch outcome {
                case .cloned:
                    print("Cloned \(cache)")
                case .skipped(let reason):
                    print("Skipped \(cache): \(reason)")
                case .failed(let reason):
                    print("Failed to seed \(cache): \(reason)")
                }
            }
            if result.caches.contains(where: { $0.1.failed }) { throw ExitCode.failure }
        } catch let error as Git.Exit {
            throw ExitCode(error.status)
        }
    }

    func create(using git: Git) throws -> (path: String, caches: [(String, CacheOutcome)]) {
        guard !path.isEmpty, !seed.isEmpty else { throw ValidationError("Provide a worktree path and a seed path.") }
        guard !cache.isEmpty else { throw ValidationError("Provide at least one --cache directory.") }
        let paths = try cache.map(CachePath.init)

        let donorPath = absolute(seed, relativeTo: git.directory)
        var donor = try git.independentWorktree(at: donorPath)
        let donorRoot = try donor.path(["rev-parse", "--show-toplevel"])
        let originalCommon = try git.path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let donorCommon = try donor.path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard try FileIdentity(donorRoot) == FileIdentity(donorPath),
              try FileIdentity(originalCommon) == FileIdentity(donorCommon) else {
            throw ValidationError("--seed must be a worktree root from this Git repository.")
        }
        let donorCaseSensitive = try volumeIsCaseSensitive(at: donorRoot)
        for (index, path) in paths.enumerated() {
            guard !paths[..<index].contains(where: { $0.overlaps(path, caseSensitive: donorCaseSensitive) }) else {
                throw ValidationError("Cache directories must be distinct and cannot contain one another: \(path.name)")
            }
        }

        var arguments = ["worktree", "add"]
        if let branch { arguments += ["-b", branch] }
        arguments += ["--", path]
        if let start { arguments.append(start) }
        try git.run(arguments)

        let destinationPath = absolute(path, relativeTo: git.directory)
        var destination = try git.independentWorktree(at: destinationPath)
        let destinationCaseSensitive = try volumeIsCaseSensitive(at: destinationPath)
        let seeder = CacheSeeder(donor: donorRoot, destination: destinationPath)
        let outcomes = paths.map { path in
            (path.name, seeder.transfer(path) {
                try donor.isIgnored(path, caseSensitive: donorCaseSensitive) &&
                    destination.isIgnored(path, caseSensitive: destinationCaseSensitive)
            })
        }
        return (destinationPath, outcomes)
    }
}

private func absolute(_ path: String, relativeTo directory: String) -> String {
    let absolutePath = path.hasPrefix("/") ? path : directory + "/" + path
    return URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().path
}

private func volumeIsCaseSensitive(at path: String) throws -> Bool {
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    return try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames ?? false
}

struct CachePath {
    let name: String
    let components: [String]
    private let comparisonComponents: [String]

    var leaf: String { components[components.count - 1] }

    init(_ name: String) throws {
        let components = name.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.lowercased() != ".git" && !$0.utf8.contains(0) }) else {
            throw ValidationError("Expected a worktree-relative cache directory: \(name)")
        }
        self.name = name
        self.components = components
        comparisonComponents = components.map(Self.comparisonKey)
    }

    func overlaps(_ other: Self, caseSensitive: Bool) -> Bool {
        let first = caseSensitive ? components : comparisonComponents
        let second = caseSensitive ? other.components : other.comparisonComponents
        return first.starts(with: second) || second.starts(with: first)
    }

    func containsIndexedPath(_ rawPath: Data, caseSensitive: Bool) -> Bool {
        let prefix = rawPath.split(separator: 0x2F, maxSplits: components.count)
        guard prefix.count >= components.count else { return false }
        let keys = caseSensitive ? components : comparisonComponents
        return zip(prefix, keys).allSatisfy { bytes, key in
            let component = String(decoding: bytes, as: UTF8.self)
            return (caseSensitive ? component : Self.comparisonKey(component)) == key
        }
    }

    private static func comparisonKey(_ component: String) -> String {
        // Treat case and canonical Unicode aliases conservatively, including
        // when examining a Git index that was authored on another filesystem.
        component.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
