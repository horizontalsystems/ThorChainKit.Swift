// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ThorChainKit",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "ThorChainKit", targets: ["ThorChainKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.0.0"),
        .package(
            url: "https://github.com/horizontalsystems/HsCryptoKit.Swift.git",
            exact: "1.3.2"
        ),
        .package(
            url: "https://github.com/horizontalsystems/HdWalletKit.Swift.git",
            exact: "1.3.2"
        ),
        .package(
            url: "https://github.com/GigaBitcoin/secp256k1.swift.git",
            exact: "0.10.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "6.29.3"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.33.3"
        ),
    ],
    targets: [
        .target(
            name: "ThorChainKit",
            dependencies: [
                "BigInt",
                .product(
                    name: "HsCryptoKit",
                    package: "HsCryptoKit.Swift"
                ),
                .product(
                    name: "HdWalletKit",
                    package: "HdWalletKit.Swift"
                ),
                .product(name: "secp256k1", package: "secp256k1.swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ThorChainKitTests",
            dependencies: [
                "ThorChainKit",
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ThorChainKitLiveTests",
            dependencies: ["ThorChainKit"],
            path: "Tests/ThorChainKitLiveTests",
            exclude: ["Fixtures"]
        ),
    ]
)
