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
                "CErlInterface",
                "DistributedMacros"
            ]
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

        .target(
            name: "CErlInterface",
            exclude: ["erl_interface/test", "erl_interface/src/prog"],
            publicHeadersPath: "erl_interface/include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("erl_interface/include"),
                .headerSearchPath("erl_interface/src/openssl/include"),
                .headerSearchPath("erl_interface/src/connect"),
                .headerSearchPath("erl_interface/src/misc"),
                .headerSearchPath("erl_interface/src/epmd"),

                .define("ERLANG_OPENSSL_INTEGRATION"),

                .define("HAVE_SOCKLEN_T")
            ]
        ),
    ]
)
