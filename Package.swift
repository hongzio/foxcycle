// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoxCycle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FoxCycle", targets: ["FoxCycle"]),
        .executable(name: "foxcycle-poc", targets: ["FoxCyclePoC"]),
    ],
    targets: [
        // Pure decision logic (ring order, shortcut matching, switch policy). No AppKit / AX.
        .target(name: "FoxCycleCore"),
        // Menu bar agent. Wrapped into FoxCycle.app by scripts/build-app.sh.
        .executableTarget(name: "FoxCycle", dependencies: ["FoxCycleCore"]),
        .testTarget(name: "FoxCycleCoreTests", dependencies: ["FoxCycleCore"]),

        // Phase 0 feasibility probe, kept frozen as a measurement tool. Swift 5 mode keeps its
        // C-callback / CF-type plumbing free of strict-concurrency noise.
        .executableTarget(
            name: "FoxCyclePoC",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
