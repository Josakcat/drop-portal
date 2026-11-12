// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DropPortal",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "DropPortal", type: .dynamic, targets: ["DropPortal"])
    ],
    dependencies: [
        // The same version as kit.minAPI in droplet.json: the oldest DroppyKit
        // the droplet uses. `droppykit update --raise` moves both.
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.23.0")
    ],
    targets: [
        // The HTTP server, parser, token and file-name rules, with no AppKit
        // or DroppyKit, so the tests run without Droppy.
        .target(name: "DropPortalCore"),
        .target(
            name: "DropPortal",
            dependencies: ["DropPortalCore", .product(name: "DroppyKit", package: "droppykit")],
            // Your own words. `droppykit build` compiles the catalog into the
            // bundle, where String(dropletLocalized:) and DropletText read
            // it; SwiftPM must not treat it as a resource of its own.
            exclude: ["Localizable.xcstrings"]
        ),
        .executableTarget(
            name: "DropPortalHarness",
            dependencies: [
                "DropPortal",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
