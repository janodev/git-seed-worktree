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
        for (index, path) in paths.enumerated() {
            guard !paths[..<index].contains(where: { $0.overlaps(path) }) else {
                throw ValidationError("Cache directories must be distinct and cannot contain one another: \(path.name)")
            }
        }

        let donorPath = absolute(seed, relativeTo: git.directory)
        let donor = try git.independentWorktree(at: donorPath)
        let donorRoot = try donor.path(["rev-parse", "--show-toplevel"])
        let originalCommon = try git.path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let donorCommon = try donor.path(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard try FileIdentity(donorRoot) == FileIdentity(donorPath),
              try FileIdentity(originalCommon) == FileIdentity(donorCommon) else {
            throw ValidationError("--seed must be a worktree root from this Git repository.")
        }

        // Check the donor before Git modifies the repository. The destination
        // ignore rules are checked separately after Git selects its revision.
        let eligible = try paths.map { try donor.isIgnored($0.name) }
        var arguments = ["worktree", "add"]
        if let branch { arguments += ["-b", branch] }
        arguments += ["--", path]
        if let start { arguments.append(start) }
        try git.run(arguments)

        let destinationPath = absolute(path, relativeTo: git.directory)
        let destination = try git.independentWorktree(at: destinationPath)
        let seeder = CacheSeeder(donor: donorRoot, destination: destinationPath)
        let outcomes = zip(paths, eligible).map { path, donorIgnores in
            let outcome: CacheOutcome
            do {
                if donorIgnores, try destination.isIgnored(path.name) {
                    outcome = seeder.transfer(path)
                } else {
                    outcome = .skipped("the cache path must be ignored in both worktrees")
                }
            } catch {
                outcome = .failed(String(describing: error))
            }
            return (path.name, outcome)
        }
        return (destinationPath, outcomes)
    }
}

private func absolute(_ path: String, relativeTo directory: String) -> String {
    let absolutePath = path.hasPrefix("/") ? path : directory + "/" + path
    return URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().path
}

struct CachePath {
    let name: String
    let components: [String]

    init(_ name: String) throws {
        let components = name.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.lowercased() != ".git" && !$0.utf8.contains(0) }) else {
            throw ValidationError("Expected a worktree-relative cache directory: \(name)")
        }
        self.name = name
        self.components = components
    }

    func overlaps(_ other: Self) -> Bool {
        components.starts(with: other.components) || other.components.starts(with: components)
    }
}
