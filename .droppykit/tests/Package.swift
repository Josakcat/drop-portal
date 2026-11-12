// swift-tools-version: 6.2
// Tests for DropPortalCore, kept outside the droplet's own package because the
// Store builds no tests. Sources/DropPortalCore is a symlink to the droplet's.
// Run from the build copy: swift test --package-path .droppykit/tests
import PackageDescription

let package = Package(
    name: "DropPortalTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DropPortalCore"),
        .testTarget(name: "DropPortalCoreTests", dependencies: ["DropPortalCore"])
    ],
    swiftLanguageModes: [.v5]
)
