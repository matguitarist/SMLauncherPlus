// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SMLauncherPlus",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // The Log page's viewer, shared by my Mac apps.
        .package(url: "https://github.com/matguitarist/LogKit", from: "0.6.0"),
        // Runs zip, the game's --help and the tests' tools, with output read safely, shared by my Mac apps.
        .package(url: "https://github.com/matguitarist/ProcessKit", from: "0.1.1"),
        // Save backups, the release zip, and ROMs and mod files read out of a .zip or .7z, shared by my Mac apps.
        .package(url: "https://github.com/matguitarist/ArchiveKit", from: "0.1.1"),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "SMLauncherPlusKit", dependencies: [.product(name: "LogKit", package: "LogKit"),
                                                         .product(name: "ProcessKit", package: "ProcessKit"),
                                                         .product(name: "ArchiveKit", package: "ArchiveKit")]),
        .executableTarget(
            name: "SMLauncherPlus",
            dependencies: ["SMLauncherPlusKit", .product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "LogKitUI", package: "LogKit"), .product(name: "ProcessKit", package: "ProcessKit"),
                           .product(name: "ArchiveKit", package: "ArchiveKit")],
            // Filter presets the launcher adds to each profile's assets/shaders (S-010).
            resources: [.copy("Shaders")],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // Sparkle.framework sits in Contents/Frameworks (build.sh copies it).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SMLauncherPlusKitTests", dependencies: ["SMLauncherPlusKit", .product(name: "ProcessKit", package: "ProcessKit")]),
    ]
)
