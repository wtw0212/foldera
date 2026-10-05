// swift-tools-version:5.10
// Joannis/swift-nio-ssh 0.3.5 (791437a), the fork Citadel 0.12.0 depends on, with Foldera's patches: see PATCHES.md.
// Foldera's project lists this local package, which overrides the remote one for Citadel too.

import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [.macOS(.v10_15), .iOS(.v13), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    // Exact versions Foldera is built and tested with (upstream: nio from 2.81.0, crypto 1.0.0..<4.0.0, atomics
    // from 1.0.2); their own dependencies are locked in Package.resolved. Bump together with project.yml.
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
            ]
        )
    ]
)
