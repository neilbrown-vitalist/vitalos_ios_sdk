// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VitalOS",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "VitalOSSDK", targets: ["VitalOSSDK"]),
        .library(name: "VitalOSBLE", targets: ["VitalOSBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "VitalOSSDK",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "VitalOSBLE",
            dependencies: ["VitalOSSDK"]
        ),
    ]
)
