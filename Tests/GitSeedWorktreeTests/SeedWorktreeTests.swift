import Darwin
import Foundation
import Testing

@testable import GitSeedWorktree

struct SeedWorktreeTests {
    @Test func clonesOnlySelectedCachesAndKeepsWritesIndependent() throws {
        let fixture = try Fixture()
        try fixture.write(".cache/nested/value", "seed")
        try fixture.write("tools/cache data/entry", "nested cache")
        try fixture.write("Artifacts/log", "unselected")
        try FileManager.default.createSymbolicLink(atPath: fixture.seed + "/.cache/link",
                                                   withDestinationPath: "nested/value")

        let result = try fixture.create(caches: [".cache", "tools/cache data"])

        #expect(result.path == fixture.destination)
        #expect(result.caches.map(\.1) == [.cloned, .cloned])
        #expect(try fixture.read("tracked.txt") == "committed")
        #expect(try fixture.read(".cache/link") == "seed")
        #expect(try fixture.read("tools/cache data/entry") == "nested cache")
        #expect(!fixture.exists("Artifacts"))
        #expect(try FileIdentity(fixture.seed + "/.cache/nested/value") !=
            FileIdentity(fixture.destination + "/.cache/nested/value"))
        let clonedFile = try FileHandle(forWritingTo: fixture.url(".cache/nested/value"))
        try clonedFile.write(contentsOf: Data("new!".utf8))
        try clonedFile.close()
        #expect(try fixture.read(".cache/link") == "new!")
        #expect(try String(contentsOfFile: fixture.seed + "/.cache/nested/value", encoding: .utf8) == "seed")
    }

    @Test func skipsExistingMissingAndUnignoredCaches() throws {
        let fixture = try Fixture()
        try fixture.write("existing/value", "seed")
        try fixture.write("unignored/value", "seed")
        let hook = fixture.repository + "/.git/hooks/post-checkout"
        try """
        #!/bin/sh
        set -eu
        mkdir existing
        printf hook > existing/value
        """.write(toFile: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook, 0o700) == 0)

        let result = try fixture.create(caches: ["existing", "missing", "unignored"])

        #expect(result.caches.map(\.1) == [
            .skipped("the destination already exists"),
            .skipped("the seed directory is absent"),
            .skipped("the cache path must be ignored in both worktrees"),
        ])
        #expect(try fixture.read("existing/value") == "hook")
        #expect(!fixture.exists("missing"))
        #expect(!fixture.exists("unignored"))
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test func rejectsLinksThatEscapeTheCacheWithoutPublishingPartialFiles() throws {
        let fixture = try Fixture()
        try fixture.write(".cache/value", "seed")
        try FileManager.default.createSymbolicLink(atPath: fixture.seed + "/.cache/link",
                                                   withDestinationPath: "../tracked.txt")

        let result = try fixture.create(caches: [".cache"])

        #expect(result.caches.map(\.1) == [.skipped("symlink link must resolve inside the cache")])
        #expect(!fixture.exists(".cache"))
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test(arguments: [true, false])
    func skipsHookCreatedSymlinksAtOrAboveTheCache(_ linkAtCache: Bool) throws {
        let fixture = try Fixture()
        try fixture.write("tools/cache data/value", "seed")
        let root = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hook = fixture.repository + "/.git/hooks/post-checkout"
        let createLink = linkAtCache ? "mkdir tools\nln -s ../../outside 'tools/cache data'" : "ln -s ../outside tools"
        try ("#!/bin/sh\nset -eu\n" + createLink + "\n").write(toFile: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook, 0o700) == 0)

        let result = try fixture.create(caches: ["tools/cache data"])

        let reason = linkAtCache ? "the destination already exists" : "the destination parent must contain real directories"
        #expect(result.caches.map(\.1) == [.skipped(reason)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test func checksIgnoreRulesAtTheDestinationRevision() throws {
        let fixture = try Fixture()
        try fixture.write(".cache/value", "seed")
        try "/Artifacts/\n".write(toFile: fixture.repository + "/.gitignore", atomically: true, encoding: .utf8)
        try fixture.git.run(["commit", "-qm", "Stop ignoring .cache", "--", ".gitignore"])

        let result = try fixture.create(caches: [".cache"])

        #expect(result.caches.map(\.1) == [.skipped("the cache path must be ignored in both worktrees")])
        #expect(!fixture.exists(".cache"))
    }

    @Test(arguments: [".cache", ".CACHE"])
    func skipsACacheWithTrackedFilesInTheSeed(_ indexedPath: String) throws {
        let fixture = try Fixture()
        try fixture.write(indexedPath + "/value", "seed")
        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["add", "-f", indexedPath + "/value"])
        try donor.run(["commit", "-qm", "Track the seed data"])
        let pathResolves = FileManager.default.fileExists(atPath: fixture.seed + "/.cache")

        let result = try fixture.create(caches: [".cache"])

        let reason = pathResolves ? "the cache path must be ignored in both worktrees" : "the seed directory is absent"
        #expect(result.caches.map(\.1) == [.skipped(reason)])
        #expect(!fixture.exists(".cache"))
    }

    @Test func usesInvocationGitConfigurationInBothWorktrees() throws {
        let fixture = try Fixture()
        try fixture.write("additional/value", "seed")
        let excludes = fixture.root.appending(path: "excludes")
        try "/additional/\n".write(to: excludes, atomically: true, encoding: .utf8)
        var invokingGit = fixture.git
        invokingGit.environment["GIT_CONFIG_COUNT"] = "1"
        invokingGit.environment["GIT_CONFIG_KEY_0"] = "core.excludesFile"
        invokingGit.environment["GIT_CONFIG_VALUE_0"] = excludes.path

        let result = try fixture.create(caches: ["additional"], using: invokingGit)

        #expect(result.caches.map(\.1) == [.cloned])
        #expect(try fixture.read("additional/value") == "seed")
    }

    @Test func comparesCanonicalUnicodeAndRespectsVolumeCaseSensitivity() throws {
        let cache = try CachePath("Café")
        let decomposed = Data("Cafe\u{0301}/tracked".utf8)
        let lowercased = Data("cafe\u{0301}/tracked".utf8)
        #expect(cache.containsIndexedPath(decomposed, caseSensitive: true))
        #expect(cache.containsIndexedPath(lowercased, caseSensitive: false))
        #expect(!cache.containsIndexedPath(lowercased, caseSensitive: true))
        #expect(!cache.containsIndexedPath(Data("Cafés/tracked".utf8), caseSensitive: false))
    }

    @Test func rejectsAForeignSeedBeforeCreatingTheWorktree() throws {
        let fixture = try Fixture()
        let foreign = fixture.root.path + "/foreign"
        try fixture.git.run(["init", "-q", foreign])

        #expect(throws: (any Error).self) { try fixture.create(caches: [".cache"], seed: foreign) }
        #expect(!fixture.exists())
    }

    @Test(arguments: ["../outside", "./.cache", "/tmp/cache", ".GiT/cache", ".cache//nested"])
    func rejectsInvalidCachePathsBeforeCreatingTheWorktree(_ cache: String) throws {
        let fixture = try Fixture()

        #expect(throws: (any Error).self) { try fixture.create(caches: [cache]) }
        #expect(!fixture.exists())
    }

    @Test func preservesNativeGitFailureAndAnOccupiedDestination() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(atPath: fixture.destination, withIntermediateDirectories: false)
        try "existing".write(to: fixture.url("value"), atomically: true, encoding: .utf8)

        let error = #expect(throws: Git.Exit.self) { try fixture.create(caches: [".cache"]) }
        #expect(error?.arguments.first == "worktree")
        #expect(try fixture.read("value") == "existing")
    }
}

private final class Fixture {
    let root: URL
    let git: Git

    var repository: String { git.directory }
    var seed: String { root.path + "/seed" }
    var destination: String { root.path + "/new worktree" }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "git-seed-worktree-tests-" + UUID().uuidString)
        let repository = root.appending(path: "repository")
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        git = Git(directory: repository.path, environment: environment)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"])
        try git.run(["config", "user.name", "Worktree Test"])
        try git.run(["config", "user.email", "worktree-test@example.invalid"])
        try "/.cache/\n/tools/cache data/\n/Artifacts/\n/existing/\n/missing/\n"
            .write(to: repository.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "committed".write(to: repository.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", ".gitignore", "tracked.txt"])
        try git.run(["commit", "-qm", "Set up fixture"])
        try git.run(["worktree", "add", "-q", "--detach", seed, "main"])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func create(caches: [String], seed seedOverride: String? = nil, using invokingGit: Git? = nil) throws
        -> (path: String, caches: [(String, CacheOutcome)]) {
        var args = ["-b", "experiment", "../new worktree", "main", "--seed", seedOverride ?? "../seed"]
        for cache in caches { args += ["--cache", cache] }
        return try SeedWorktree.parse(args).create(using: invokingGit ?? git)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let file = URL(fileURLWithPath: seed + "/" + relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func url(_ relativePath: String) -> URL { URL(fileURLWithPath: destination + "/" + relativePath) }

    func read(_ relativePath: String) throws -> String { try String(contentsOf: url(relativePath), encoding: .utf8) }

    func exists(_ relativePath: String = "") -> Bool { FileManager.default.fileExists(atPath: url(relativePath).path) }

    func stagingEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination).filter { $0.hasPrefix(".git-seed-worktree-") }
    }
}
