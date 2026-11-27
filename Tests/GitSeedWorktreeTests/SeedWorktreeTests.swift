import Darwin
import Foundation
import Testing

@testable import GitSeedWorktree

struct SeedWorktreeTests {
    @Test func clonesCommittedFilesAndLetsGitReconcileBranchesAndSubmodules() throws {
        let fixture = try Fixture()
        func writeTracked(_ name: String, _ content: String) throws {
            try content.write(toFile: fixture.repository + "/" + name, atomically: true, encoding: .utf8)
        }
        try writeTracked("changed.txt", "old")
        try writeTracked("dirty.txt", "committed seed value")
        try writeTracked("removed.txt", "seed only")
        try writeTracked("run.sh", "#!/bin/sh\n")
        try #require(chmod(fixture.repository + "/run.sh", 0o755) == 0)
        try fixture.git.run(["add", "changed.txt", "dirty.txt", "removed.txt", "run.sh"])
        let base = try fixture.git.path(["rev-parse", "HEAD"])
        try fixture.git.run(["update-index", "--add", "--cacheinfo", "160000,\(base),module"])
        try fixture.git.run(["commit", "-qm", "Add a branch comparison fixture"])
        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])
        try donor.run(["update-index", "--assume-unchanged", "dirty.txt"])
        try fixture.write("dirty.txt", "uncommitted seed value")
        try fixture.write("module/local", "uncommitted module data")
        try fixture.write("untracked", "local seed data")
        try writeTracked("changed.txt", "new")
        try writeTracked("new.txt", "target only")
        try fixture.git.run(["add", "changed.txt", "new.txt"])
        try fixture.git.run(["rm", "-q", "removed.txt"])
        try fixture.git.run(["commit", "-qm", "Advance the target branch"])

        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .finished(cloned: 3, checkedOut: 4))
        #expect(try fixture.read("changed.txt") == "new")
        #expect(try fixture.read("dirty.txt") == "committed seed value")
        #expect(try fixture.read("new.txt") == "target only")
        #expect(!fixture.exists("removed.txt"))
        #expect(!fixture.exists("untracked"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("module").path).isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: fixture.url("run.sh").path))
        #expect(try FileIdentity(fixture.seed + "/tracked.txt") != FileIdentity(fixture.url("tracked.txt").path))
        #expect(try String(contentsOfFile: fixture.seed + "/dirty.txt", encoding: .utf8) == "uncommitted seed value")
        let destination = try fixture.git.independentWorktree(at: fixture.destination)
        #expect(try destination.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test func sendsTransformedFilesThroughGitEvenWhenTheSeedMatchesTheRawBlob() throws {
        let fixture = try Fixture()
        try "converted.txt text eol=crlf\n".write(toFile: fixture.repository + "/.gitattributes",
                                                 atomically: true, encoding: .utf8)
        try "committed\n".write(toFile: fixture.repository + "/converted.txt", atomically: true, encoding: .utf8)
        try fixture.git.run(["add", ".gitattributes", "converted.txt"])
        try fixture.git.run(["commit", "-qm", "Require checkout conversion"])
        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])
        try fixture.write("converted.txt", "committed\n")

        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .finished(cloned: 3, checkedOut: 1))
        #expect(try fixture.read("converted.txt") == "committed\r\n")
    }

    @Test func usesAStandardWorktreeCheckoutForAutomaticLineEndingConversion() throws {
        let fixture = try Fixture()
        try fixture.git.run(["config", "core.autocrlf", "true"])

        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .standard("core.autocrlf uses Git's standard checkout"))
        #expect(try fixture.read("tracked.txt") == "committed")
    }

    @Test func preservesAFailedPostCheckoutHooksExitStatus() throws {
        let fixture = try Fixture()
        let hook = fixture.repository + "/.git/hooks/post-checkout"
        try "#!/bin/sh\nexit 42\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook, 0o700) == 0)

        let error = #expect(throws: TrackedCheckoutFailure.self) { try fixture.create(cloneTracked: true) }

        #expect((error?.cause as? Git.Exit)?.status == 42)
        #expect(try fixture.read("tracked.txt") == "committed")
        #expect(try fixture.stagingEntries().isEmpty)
    }

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

    @Test func honorsAttrTreeGitAttrSourceMacrosAndExternalAttributes() throws {
        let fixture = try Fixture()
        try fixture.git.run(["config", "filter.upper.smudge", "tr a-z A-Z"])
        try fixture.git.run(["config", "filter.upper.clean", "tr A-Z a-z"])
        let externalAttributes = fixture.root.appending(path: "external-attributes")
        try "ext.txt eol=crlf\n".write(to: externalAttributes, atomically: true, encoding: .utf8)
        try fixture.git.run(["config", "core.attributesFile", externalAttributes.path])

        let subDir = fixture.repository + "/sub"
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        try "[attr]shout filter=upper\n*.macro shout\n*.id ident\n"
            .write(toFile: fixture.repository + "/.gitattributes", atomically: true, encoding: .utf8)
        try "*.txt eol=crlf\n".write(toFile: subDir + "/.gitattributes", atomically: true, encoding: .utf8)
        for (name, content) in [
            ("macro.macro", "hello\n"),
            ("ident.id", "$Id$\n"),
            ("sub/file.txt", "subline\n"),
            ("ext.txt", "extline\n"),
            ("treeattr.dat", "treeline\n"),
        ] {
            let blob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data(content.utf8))
            try fixture.git.run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(name)"])
        }
        try fixture.git.run(["add", ".gitattributes", "sub/.gitattributes"])
        try fixture.git.run(["commit", "-qm", "Add attribute test fixtures"])

        // Create a separate branch whose .gitattributes converts treeattr.dat.
        try fixture.git.run(["checkout", "-q", "-b", "attr-branch"])
        try "treeattr.dat filter=upper\n".write(toFile: fixture.repository + "/.gitattributes",
                                                atomically: true, encoding: .utf8)
        try fixture.git.run(["add", ".gitattributes"])
        try fixture.git.run(["commit", "-qm", "Add attr.tree branch"])
        try fixture.git.run(["checkout", "-q", "main"])

        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])
        // Seed raw blob bytes so bypassing conversion would silently clone them.
        try fixture.write("macro.macro", "hello\n")
        try fixture.write("ident.id", "$Id$\n")
        try fixture.write("sub/file.txt", "subline\n")
        try fixture.write("ext.txt", "extline\n")
        try fixture.write("treeattr.dat", "treeline\n")

        // Verify GIT_ATTR_SOURCE is honored (without mutating repo config yet).
        var envGit = fixture.git
        envGit.environment["GIT_ATTR_SOURCE"] = "attr-branch"
        let envResult = try fixture.create(using: envGit, cloneTracked: true)
        #expect(envResult.tracked == .finished(cloned: 6, checkedOut: 3))
        #expect(try fixture.read("treeattr.dat") == "TREELINE\n")
        #expect(try fixture.read("ext.txt") == "extline\r\n")

        // Verify attr.tree config is honored as well as index macros/ident/sub-dir attrs.
        try fixture.git.run(["config", "attr.tree", "attr-branch"])
        let treeDest = fixture.root.path + "/attr-tree-wt"
        let treeResult = try SeedWorktree.parse([
            "-b", "attr-tree-exp", treeDest, "main", "--seed", fixture.seed, "--clone-tracked",
        ]).create(using: fixture.git)
        #expect(treeResult.tracked == .finished(cloned: 6, checkedOut: 3))
        #expect(try String(contentsOfFile: treeDest + "/treeattr.dat", encoding: .utf8) == "TREELINE\n")
        #expect(try String(contentsOfFile: treeDest + "/ext.txt", encoding: .utf8) == "extline\r\n")

        // Unset attr.tree to verify index .gitattributes macros, ident, and subdirectory rules.
        try fixture.git.run(["config", "--unset", "attr.tree"])
        let indexDest = fixture.root.path + "/index-attrs-wt"
        let indexResult = try SeedWorktree.parse([
            "-b", "index-attrs-exp", indexDest, "main", "--seed", fixture.seed, "--clone-tracked",
        ]).create(using: fixture.git)
        #expect(indexResult.tracked == .finished(cloned: 5, checkedOut: 4))
        #expect(try String(contentsOfFile: indexDest + "/macro.macro", encoding: .utf8) == "HELLO\n")
        #expect(try String(contentsOfFile: indexDest + "/sub/file.txt", encoding: .utf8) == "subline\r\n")
        #expect(try String(contentsOfFile: indexDest + "/ext.txt", encoding: .utf8) == "extline\r\n")
        #expect(try String(contentsOfFile: indexDest + "/ident.id", encoding: .utf8).hasPrefix("$Id: "))
    }

    @Test func reconcilesCaseAndUnicodePathCollisionsLikeNativeGit() throws {
        let fixture = try Fixture()
        let sameBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("same\n".utf8))
        let upperBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("UPPER\n".utf8))
        let lowerBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("lower\n".utf8))
        let cleanBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("clean\n".utf8))
        let gitignoreBlob = try fixture.git.path(["rev-parse", "HEAD:.gitignore"])
        let trackedBlob = try fixture.git.path(["rev-parse", "HEAD:tracked.txt"])
        let subTree = try fixture.git.path(["mktree"], input: Data("100644 blob \(lowerBlob)\tnested.txt\n".utf8))
        var treeInput = Data()
        for line in [
            "100644 blob \(gitignoreBlob)\t.gitignore\n",
            "100644 blob \(sameBlob)\tA.txt\n",
            "100644 blob \(upperBlob)\tDiff.txt\n",
            "100644 blob \(upperBlob)\tEntry\n",
            "100644 blob \(sameBlob)\ta.txt\n",
            "100644 blob \(cleanBlob)\tclean.txt\n",
            "100644 blob \(lowerBlob)\tdiff.txt\n",
            "040000 tree \(subTree)\tentry\n",
            "100644 blob \(trackedBlob)\ttracked.txt\n",
        ] {
            treeInput.append(Data(line.utf8))
        }
        treeInput.append(Data("100644 blob \(sameBlob)\t".utf8))
        treeInput.append(Data("Café.txt".precomposedStringWithCanonicalMapping.utf8))
        treeInput.append(Data("\n100644 blob \(sameBlob)\t".utf8))
        treeInput.append(Data("Café.txt".decomposedStringWithCanonicalMapping.utf8))
        treeInput.append(Data("\n".utf8))
        let tree = try fixture.git.path(["mktree"], input: treeInput)
        let parent = try fixture.git.path(["rev-parse", "HEAD"])
        let commit = try fixture.git.path(["commit-tree", tree, "-p", parent, "-m", "Add collisions"])
        try fixture.git.run(["update-ref", "refs/heads/main", commit])

        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "-f", "--detach", "main"])

        let nativeDest = fixture.root.path + "/native-wt"
        try fixture.git.run(["worktree", "add", "-q", "-b", "native", nativeDest, "main"])
        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .finished(cloned: 3, checkedOut: 8))
        #expect(try fixture.read("clean.txt") == "clean\n")
        #expect(try FileIdentity(fixture.seed + "/clean.txt") != FileIdentity(fixture.url("clean.txt").path))
        let nativeGit = try fixture.git.independentWorktree(at: nativeDest)
        let seededGit = try fixture.git.independentWorktree(at: fixture.destination)
        #expect(try seededGit.capture(["status", "--porcelain", "--untracked-files=no"]) ==
            nativeGit.capture(["status", "--porcelain", "--untracked-files=no"]))
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test func runsPostCheckoutHookWithoutLeakingGitDirAndSupportsHooksPath() throws {
        let fixture = try Fixture()
        let other = fixture.root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherGit = Git(directory: other.path, environment: fixture.git.environment)
        try otherGit.run(["init", "-q", "-b", "other-branch"])
        try otherGit.run(["config", "user.name", "Worktree Test"])
        try otherGit.run(["config", "user.email", "worktree-test@example.invalid"])
        try "other".write(to: other.appending(path: "o.txt"), atomically: true, encoding: .utf8)
        try otherGit.run(["add", "o.txt"])
        try otherGit.run(["commit", "-qm", "Other commit"])

        let hooksDir = fixture.repository + "/.githooks"
        try FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        let hook = hooksDir + "/post-checkout"
        try """
        #!/bin/sh
        set -eu
        git rev-parse --abbrev-ref HEAD > own-branch
        git -C "\(other.path)" rev-parse --abbrev-ref HEAD > other-branch
        test -z "${GIT_DIR:-}"
        """.write(toFile: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook, 0o700) == 0)
        try fixture.git.run(["add", ".githooks/post-checkout"])
        try fixture.git.run(["commit", "-qm", "Add repo hooks"])
        try fixture.git.run(["config", "core.hooksPath", ".githooks"])

        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .standard("post-checkout hooks use Git's standard checkout"))
        #expect(try fixture.read("own-branch") == "experiment\n")
        #expect(try fixture.read("other-branch") == "other-branch\n")

        // Verify core.hooksPath=/dev/null disables hooks cleanly without failing rev-parse.
        try fixture.git.run(["config", "core.hooksPath", "/dev/null"])
        let disabledDest = fixture.root.path + "/no-hooks-wt"
        let disabled = try SeedWorktree.parse([
            "-b", "no-hooks", disabledDest, "main", "--seed", fixture.seed, "--clone-tracked",
        ]).create(using: fixture.git)
        #expect(disabled.tracked == .finished(cloned: 2, checkedOut: 1))
        #expect(!FileManager.default.fileExists(atPath: disabledDest + "/own-branch"))
    }

    @Test(arguments: ["worktree", "gitdir", "onbranch"])
    func usesDestinationConfigurationForCheckout(_ scope: String) throws {
        let fixture = try Fixture()
        if scope == "worktree" {
            try fixture.git.run(["config", "extensions.worktreeConfig", "true"])
            try fixture.git.run(["config", "--worktree", "core.autocrlf", "true"])
        } else {
            let config = fixture.root.appending(path: "checkout.gitconfig")
            try Data("[core]\n\tautocrlf = true\n".utf8).write(to: config)
            let condition = scope == "gitdir" ? "gitdir:**/worktrees/**" : "onbranch:exp*"
            try fixture.git.run(["config", "includeIf." + condition + ".path", config.path])
        }

        let native = fixture.root.appending(path: "native")
        try fixture.git.run(["worktree", "add", "-q", "-b", "expected", native.path, "main"])
        let result = try fixture.create(cloneTracked: true)
        let expected = try Data(contentsOf: native.appending(path: ".gitignore"))
        #expect(expected.contains(0x0D))
        #expect(try Data(contentsOf: fixture.url(".gitignore")) == expected)
        #expect(result.tracked == .standard("core.autocrlf uses Git's standard checkout"))
    }

    @Test(arguments: ["sha1", "sha256"], [false, true])
    func runsConfiguredHooksWithAndWithoutAHookFile(_ format: String, _ hasHookFile: Bool) throws {
        let fixture = try Fixture(objectFormat: format)
        let head = try fixture.git.path(["rev-parse", "HEAD"])
        try fixture.git.run(["config", "hook.setup.event", "post-checkout"])
        try fixture.git.run(["config", "hook.setup.command", "echo configured >> hook-log; :"])
        if hasHookFile {
            let hook = fixture.repository + "/.git/hooks/post-checkout"
            try Data("""
                test -z "${GIT_DIR:-}" && test -z "${GIT_WORK_TREE:-}" || exit 8
                cat tracked.txt >> hook-log
                printf ' %s\\n' "$@" >> hook-log
                """.utf8).write(to: URL(fileURLWithPath: hook))
            try #require(chmod(hook, 0o700) == 0)
        }
        try fixture.write(".cache/item", "cached")

        let native = fixture.root.appending(path: "native")
        try fixture.git.run(["worktree", "add", "-q", "--detach", native.path, "main"])
        let result = try fixture.create(caches: [".cache"], cloneTracked: true)

        let expected = try String(contentsOf: native.appending(path: "hook-log"), encoding: .utf8)
        let hookArguments = String(repeating: "0", count: head.count) + "\n \(head)\n 1\n"
        #expect(expected == (hasHookFile ? "configured\ncommitted " + hookArguments : "configured\n"))
        #expect(try fixture.read("hook-log") == expected)
        #expect(result.caches.map(\.1) == [.cloned])
        #expect(try fixture.read(".cache/item") == "cached")
    }

    @Test func clonesDeepCachesUnderABoundedDescriptorLimit() throws {
        let fixture = try Fixture()
        let leaf = ".cache/" + String(repeating: "d/", count: 145) + "item"
        try fixture.write(leaf, "deep value")
        let executable = Bundle(for: Fixture.self).bundleURL
            .deletingLastPathComponent().appending(path: "git-seed-worktree").path
        // Limit only the child, including its hard limit. Other tests run concurrently.
        let result = try runCLI("/bin/sh", in: fixture.repository, environment: fixture.git.environment,
                                arguments: ["-c", "ulimit -n 256 && exec \"$@\"", "cache-test",
                                            executable, "-b", "deep", fixture.destination, "main",
                                            "--seed", fixture.seed, "--cache", ".cache"])
        try #require(result.status == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(try fixture.read(leaf) == "deep value")
        #expect(try fixture.stagingEntries().isEmpty)
    }

    @Test func honorsEffectiveGitConfigAndStandardCheckoutFallbacks() throws {
        let fixture = try Fixture()
        let globalConfig = fixture.root.appending(path: "global.gitconfig")
        try "[core]\n\tautocrlf = true\n".write(to: globalConfig, atomically: true, encoding: .utf8)
        var invokingGit = fixture.git
        invokingGit.environment["GIT_CONFIG_GLOBAL"] = globalConfig.path
        try invokingGit.run(["config", "core.autocrlf", "false"])

        // Local false overrides global true, so --clone-tracked should still clone.
        let overridden = try fixture.create(using: invokingGit, cloneTracked: true)
        #expect(overridden.tracked == .finished(cloned: 2, checkedOut: 0))

        // submodule.recurse = true falls back to standard checkout.
        try fixture.git.run(["config", "submodule.recurse", "true"])
        let recurseDest = fixture.root.path + "/recurse-wt"
        let recurse = try SeedWorktree.parse([
            "-b", "recurse-exp", recurseDest, "main", "--seed", fixture.seed, "--clone-tracked",
        ]).create(using: fixture.git)
        #expect(recurse.tracked == .standard("submodule.recurse uses Git's standard checkout"))
        try fixture.git.run(["config", "--unset", "submodule.recurse"])

        // An orphan seed with no commit falls back to standard checkout.
        let orphanSeed = fixture.root.path + "/orphan-seed"
        try fixture.git.run(["worktree", "add", "-q", "--orphan", "-b", "orphan", orphanSeed])
        let orphanDest = fixture.root.path + "/orphan-wt"
        let orphan = try SeedWorktree.parse([
            "-b", "orphan-exp", orphanDest, "main", "--seed", orphanSeed, "--clone-tracked",
        ]).create(using: fixture.git)
        #expect(orphan.tracked == .standard("the seed has no commit"))
    }

    @Test func handlesSparseSeedsAndSparseInvokingWorktrees() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(atPath: fixture.repository + "/dirA", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fixture.repository + "/dirB", withIntermediateDirectories: true)
        try "alpha".write(toFile: fixture.repository + "/dirA/a.txt", atomically: true, encoding: .utf8)
        try "beta".write(toFile: fixture.repository + "/dirB/b.txt", atomically: true, encoding: .utf8)
        try fixture.git.run(["add", "dirA/a.txt", "dirB/b.txt"])
        try fixture.git.run(["commit", "-qm", "Add sparse directories"])

        let sparseSeed = try fixture.git.independentWorktree(at: fixture.seed)
        try sparseSeed.run(["checkout", "-q", "--detach", "main"])
        try sparseSeed.run(["sparse-checkout", "init", "--cone", "--sparse-index"])
        try sparseSeed.run(["sparse-checkout", "set", "dirB"])

        // Invoked from a full worktree against a sparse seed: clones present files, Git checks out missing ones.
        let fullResult = try fixture.create(cloneTracked: true)
        #expect(fullResult.tracked == .finished(cloned: 3, checkedOut: 1))
        #expect(try fixture.read("dirA/a.txt") == "alpha")
        #expect(try fixture.read("dirB/b.txt") == "beta")
        let fullDest = try fixture.git.independentWorktree(at: fixture.destination)
        #expect(try fullDest.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)

        // Invoked from the sparse worktree itself: falls back to standard checkout and preserves sparseness.
        let sparseDest = fixture.root.path + "/sparse-wt"
        let sparseResult = try SeedWorktree.parse([
            "-b", "sparse-exp", sparseDest, "main", "--seed", fixture.seed, "--clone-tracked",
        ]).create(using: sparseSeed)
        #expect(sparseResult.tracked == .standard("core.sparsecheckout uses Git's standard checkout"))
        #expect(!FileManager.default.fileExists(atPath: sparseDest + "/dirA/a.txt"))
        #expect(try String(contentsOfFile: sparseDest + "/dirB/b.txt", encoding: .utf8) == "beta")
    }

    @Test func clonesTrackedFilesAndCachesInSHA256Repositories() throws {
        let fixture = try Fixture(objectFormat: "sha256")
        try Data("committed-dirty".utf8).write(to: URL(fileURLWithPath: fixture.repository + "/dirty.txt"))
        try fixture.git.run(["add", "dirty.txt"])
        try fixture.git.run(["commit", "-qm", "Add dirty test file"])
        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])
        try fixture.write("dirty.txt", "modified in seed")
        try fixture.write(".cache/item", "cached")
        let result = try fixture.create(caches: [".cache"], cloneTracked: true)

        #expect(result.tracked == .finished(cloned: 2, checkedOut: 1))
        #expect(result.caches.map(\.1) == [.cloned])
        #expect(try fixture.read("tracked.txt") == "committed")
        #expect(try fixture.read("dirty.txt") == "committed-dirty")
        #expect(try fixture.read(".cache/item") == "cached")
        let head = try fixture.git.path(["rev-parse", "HEAD"])
        #expect(head.count == 64)
        let destination = try fixture.git.independentWorktree(at: fixture.destination)
        #expect(try destination.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)
    }

    @Test func handlesTrackedSymlinksSpecialFilenamesAndSeedMetadataGuards() throws {
        let fixture = try Fixture()
        let xattrBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("xattr".utf8))
        let lockedBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("locked".utf8))
        let linkBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("tracked.txt".utf8))
        let weirdBlob = try fixture.git.path(["hash-object", "-w", "--stdin"], input: Data("weird".utf8))
        let gitignoreBlob = try fixture.git.path(["rev-parse", "HEAD:.gitignore"])
        let trackedBlob = try fixture.git.path(["rev-parse", "HEAD:tracked.txt"])
        let treeInput = Data("""
        100644 blob \(weirdBlob)\t-dash.txt
        100644 blob \(gitignoreBlob)\t.gitignore
        100644 blob \(weirdBlob)\t:colon.txt
        120000 blob \(linkBlob)\tlink.txt
        100644 blob \(lockedBlob)\tlocked.txt
        100644 blob \(trackedBlob)\ttracked.txt
        100644 blob \(xattrBlob)\txattr.txt

        """.utf8)
        let tree = try fixture.git.path(["mktree"], input: treeInput)
        let parent = try fixture.git.path(["rev-parse", "HEAD"])
        let commit = try fixture.git.path(["commit-tree", tree, "-p", parent, "-m", "Add special entries"])
        try fixture.git.run(["update-ref", "refs/heads/main", commit])

        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])
        let xattrPath = fixture.seed + "/xattr.txt"
        let attrValue = Array("custom".utf8)
        try #require(setxattr(xattrPath, "user.custom", attrValue, attrValue.count, 0, 0) == 0)
        let lockedPath = fixture.seed + "/locked.txt"
        try #require(chflags(lockedPath, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(lockedPath, 0) }
        try #require(chmod(fixture.seed + "/tracked.txt", 0o755) == 0)

        let result = try fixture.create(cloneTracked: true)

        #expect(result.tracked == .finished(cloned: 4, checkedOut: 3))
        #expect(try fixture.read("-dash.txt") == "weird")
        #expect(try fixture.read(":colon.txt") == "weird")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("link.txt").path) == "tracked.txt")
        #expect(getxattr(fixture.url("xattr.txt").path, "user.custom", nil, 0, 0, 0) == -1)
        var lockedInfo = stat()
        try #require(lstat(fixture.url("locked.txt").path, &lockedInfo) == 0)
        #expect(lockedInfo.st_flags == 0)
        #expect(!FileManager.default.isExecutableFile(atPath: fixture.url("tracked.txt").path))
        let destination = try fixture.git.independentWorktree(at: fixture.destination)
        #expect(try destination.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)
    }

    @Test func rejectsGitMetadataLockedItemsAndSpecialFilesInsideCachesAndPreservesUmaskMode() throws {
        let fixture = try Fixture()
        try "/.gitcache/\n/.lockedcache/\n/.fifocache/\n/tools/cache/\n"
            .write(toFile: fixture.repository + "/.gitignore", atomically: true, encoding: .utf8)
        try fixture.git.run(["commit", "-qm", "Ignore test caches", "--", ".gitignore"])
        let donor = try fixture.git.independentWorktree(at: fixture.seed)
        try donor.run(["checkout", "-q", "--detach", "main"])

        try fixture.write(".gitcache/.git/HEAD", "ref: refs/heads/main\n")
        try fixture.write(".lockedcache/item", "locked")
        let lockedItem = fixture.seed + "/.lockedcache/item"
        try #require(chflags(lockedItem, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(lockedItem, 0) }
        try FileManager.default.createDirectory(atPath: fixture.seed + "/.fifocache", withIntermediateDirectories: true)
        try #require(mkfifo(fixture.seed + "/.fifocache/pipe", 0o600) == 0)
        try fixture.write("tools/cache/sub/item", "ok")

        let result = try fixture.create(caches: [".gitcache", ".lockedcache", ".fifocache", "tools/cache"])

        #expect(result.caches.map(\.1) == [
            .skipped("Git metadata at .git"),
            .skipped("locked item at item"),
            .skipped("unsupported filesystem entry at pipe"),
            .cloned,
        ])
        #expect(!fixture.exists(".gitcache"))
        #expect(!fixture.exists(".lockedcache"))
        #expect(!fixture.exists(".fifocache"))
        #expect(try fixture.stagingEntries().isEmpty)

        let expectedDirMode = mode_t(0o777) & ~getumask()
        for rel in ["tools", "tools/cache", "tools/cache/sub"] {
            var info = stat()
            try #require(lstat(fixture.url(rel).path, &info) == 0)
            #expect(info.st_mode & 0o777 == expectedDirMode)
        }
    }

    @Test func leavesAUsableWorktreeWhenCloningIsUnsupportedAcrossVolumesOrNonAPFS() throws {
        let fixture = try Fixture()
        try fixture.write(".cache/item", "cached")
        let hfsImage = fixture.root.appending(path: "hfs.dmg")
        let hfsMount = fixture.root.appending(path: "hfs-mount")
        try FileManager.default.createDirectory(at: hfsMount, withIntermediateDirectories: true)
        try runProcess("/usr/bin/hdiutil", ["create", "-quiet", "-size", "10m", "-fs", "HFS+",
                                            "-volname", "GswTestHFS", hfsImage.path])
        try runProcess("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", hfsMount.path, hfsImage.path])
        defer { try? runProcess("/usr/bin/hdiutil", ["detach", "-quiet", "-force", hfsMount.path]) }

        // 1. Cross-volume (APFS seed -> HFS+ destination): EXDEV fallback leaves a usable worktree.
        let crossDest = hfsMount.appending(path: "cross-wt").path
        let crossResult = try SeedWorktree.parse([
            "-b", "cross-exp", crossDest, "main", "--seed", fixture.seed, "--clone-tracked", "--cache", ".cache",
        ]).create(using: fixture.git)
        #expect(crossResult.tracked == .finished(cloned: 0, checkedOut: 2))
        #expect(crossResult.caches.map(\.1) == [.skipped("the source and destination cannot share disk blocks")])
        #expect(try String(contentsOfFile: crossDest + "/tracked.txt", encoding: .utf8) == "committed")
        let crossGit = try fixture.git.independentWorktree(at: crossDest)
        #expect(try crossGit.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)

        // 2. Same non-APFS volume (HFS+ seed -> HFS+ destination): ENOTSUP fallback leaves a usable worktree.
        let hfsRepo = hfsMount.appending(path: "repo").path
        try FileManager.default.createDirectory(atPath: hfsRepo, withIntermediateDirectories: true)
        let hfsGit = Git(directory: hfsRepo, environment: fixture.git.environment)
        try hfsGit.run(["init", "-q", "-b", "main"])
        try hfsGit.run(["config", "user.name", "Worktree Test"])
        try hfsGit.run(["config", "user.email", "worktree-test@example.invalid"])
        try "/.cache/\n".write(toFile: hfsRepo + "/.gitignore", atomically: true, encoding: .utf8)
        try "hfs-content".write(toFile: hfsRepo + "/tracked.txt", atomically: true, encoding: .utf8)
        try hfsGit.run(["add", ".gitignore", "tracked.txt"])
        try hfsGit.run(["commit", "-qm", "Init HFS"])
        let hfsSeed = hfsMount.appending(path: "seed").path
        try hfsGit.run(["worktree", "add", "-q", "--detach", hfsSeed, "main"])
        try FileManager.default.createDirectory(atPath: hfsSeed + "/.cache", withIntermediateDirectories: true)
        try "cached".write(toFile: hfsSeed + "/.cache/item", atomically: true, encoding: .utf8)
        let hfsDest = hfsMount.appending(path: "wt").path
        let hfsResult = try SeedWorktree.parse([
            "-b", "hfs-exp", hfsDest, "main", "--seed", hfsSeed, "--clone-tracked", "--cache", ".cache",
        ]).create(using: hfsGit)
        #expect(hfsResult.tracked == .finished(cloned: 0, checkedOut: 2))
        #expect(hfsResult.caches.map(\.1) == [.skipped("the source and destination cannot share disk blocks")])
        #expect(try String(contentsOfFile: hfsDest + "/tracked.txt", encoding: .utf8) == "hfs-content")
        let hfsDestGit = try hfsGit.independentWorktree(at: hfsDest)
        #expect(try hfsDestGit.capture(["status", "--porcelain", "--untracked-files=no"]).isEmpty)
    }

    @Test func cliExecutableReportsOutcomesAndPreservesExitCodes() throws {
        let fixture = try Fixture()
        let executable = Bundle(for: Fixture.self).bundleURL
            .deletingLastPathComponent().appending(path: "git-seed-worktree").path
        try #require(FileManager.default.isExecutableFile(atPath: executable))
        try fixture.write(".cache/item", "cached")

        // Omitted -b and start creates a DWIM branch matching the worktree basename.
        let dwimDest = fixture.root.path + "/dwim-branch"
        let ok = try runCLI(executable, in: fixture.repository, environment: fixture.git.environment,
                            arguments: [dwimDest, "--seed", fixture.seed, "--clone-tracked", "--cache", ".cache"])
        #expect(ok.status == 0)
        #expect(ok.stdout.contains("Worktree: \(dwimDest)"))
        #expect(ok.stdout.contains("Tracked files: cloned 2, checked out by Git 0"))
        #expect(ok.stdout.contains("Cloned .cache"))
        let dwimGit = try fixture.git.independentWorktree(at: dwimDest)
        #expect(try dwimGit.path(["rev-parse", "--abbrev-ref", "HEAD"]) == "dwim-branch")

        // Failed post-checkout hook preserves hook's exit status and reports the path on stderr.
        let hook = fixture.repository + "/.git/hooks/post-checkout"
        try "#!/bin/sh\nexit 42\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try #require(chmod(hook, 0o700) == 0)
        let failedHookDest = fixture.root.path + "/failed-hook-wt"
        let hookFail = try runCLI(executable, in: fixture.repository, environment: fixture.git.environment,
                                  arguments: ["-b", "hook-fail", failedHookDest, "main",
                                              "--seed", fixture.seed, "--clone-tracked"])
        #expect(hookFail.status == 42)
        #expect(hookFail.stderr.contains("Checkout did not finish in \(failedHookDest)"))
        try FileManager.default.removeItem(atPath: hook)

        // Unreadable file in cache triggers .failed outcome and nonzero exit after reporting worktree path.
        try fixture.write(".cache/unreadable", "secret")
        let unreadable = fixture.seed + "/.cache/unreadable"
        try #require(chmod(unreadable, 0o000) == 0)
        defer { _ = chmod(unreadable, 0o600) }
        let failedCacheDest = fixture.root.path + "/failed-cache-wt"
        let cacheFail = try runCLI(executable, in: fixture.repository, environment: fixture.git.environment,
                                   arguments: ["-b", "cache-fail", failedCacheDest, "main",
                                               "--seed", fixture.seed, "--cache", ".cache"])
        #expect(cacheFail.status == 1)
        #expect(cacheFail.stdout.contains("Worktree: \(failedCacheDest)"))
        #expect(cacheFail.stdout.contains("Failed to seed .cache:"))
    }
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    try child.run()
    child.waitUntilExit()
    try #require(child.terminationStatus == 0)
}

private func runCLI(_ executable: String, in directory: String, environment: [String: String],
                    arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.currentDirectoryURL = URL(fileURLWithPath: directory)
    child.environment = environment
    child.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    child.standardOutput = outPipe
    child.standardError = errPipe
    try child.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    return (child.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

private final class Fixture {
    let root: URL
    let git: Git

    var repository: String { git.directory }
    var seed: String { root.path + "/seed" }
    var destination: String { root.path + "/new worktree" }

    init(objectFormat: String = "sha1") throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "git-seed-worktree-tests-" + UUID().uuidString)
        let repository = root.appending(path: "repository")
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        git = Git(directory: repository.path, environment: environment)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git.run(["init", "-q", "--object-format=\(objectFormat)", "-b", "main"])
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

    func create(caches: [String] = [], seed seedOverride: String? = nil, using invokingGit: Git? = nil,
                cloneTracked: Bool = false) throws -> SeededWorktree {
        var args = ["-b", "experiment", "../new worktree", "main", "--seed", seedOverride ?? "../seed"]
        if cloneTracked { args.append("--clone-tracked") }
        for cache in caches { args += ["--cache", cache] }
        return try SeedWorktree.parse(args).create(using: invokingGit ?? git)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let file = URL(fileURLWithPath: seed + "/" + relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file, options: .atomic)
    }

    func url(_ relativePath: String) -> URL { URL(fileURLWithPath: destination + "/" + relativePath) }

    func read(_ relativePath: String) throws -> String { try String(contentsOf: url(relativePath), encoding: .utf8) }

    func exists(_ relativePath: String = "") -> Bool { FileManager.default.fileExists(atPath: url(relativePath).path) }

    func stagingEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination).filter { $0.hasPrefix(".git-seed-worktree-") }
    }
}
