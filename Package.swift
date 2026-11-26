// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "git-seed-worktree",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "git-seed-worktree", targets: ["GitSeedWorktree"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(name: "GitSeedWorktree", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "GitSeedWorktreeTests", dependencies: ["GitSeedWorktree"]),
    ],
    swiftLanguageModes: [.v6]
)
