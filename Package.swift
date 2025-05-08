// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "ErlangActorSystem",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ErlangActorSystem",
            targets: ["ErlangActorSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ErlangActorSystem",
            dependencies: [
                "erl_interface",
                "DistributedMacros"
            ]
        ),
    
        .binaryTarget(
            name: "erl_interface",
            url: "https://github.com/otp-interop/elixir_pack/releases/download/27.3.3/erl_interface.xcframework.zip",
            checksum: "330d39525666391be596268b0725387974ebf00e6430b0394512573a229c91a8"
        ),
    
        .macro(
            name: "DistributedMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
    
        .testTarget(
            name: "ErlangActorSystemTests",
            dependencies: ["ErlangActorSystem"]
        ),
    ]
)
