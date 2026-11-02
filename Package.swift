// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "easyfind",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EasyFindCore", targets: ["EasyFindCore"]),
        .executable(name: "EasyFindApp", targets: ["EasyFindApp"])
    ],
    targets: [
        .target(
            name: "EasyFindCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EasyFindApp",
            dependencies: ["EasyFindCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "EasyFindCoreTests",
            dependencies: ["EasyFindCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)