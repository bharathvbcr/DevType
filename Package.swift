// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DevType",
            targets: ["DevTypeApp"]
        ),
        .library(
            name: "ExpanderEngine",
            targets: ["ExpanderEngine"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "ExpanderEngine",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "DevTypeApp",
            dependencies: ["ExpanderEngine"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "ExpanderEngineTests",
            dependencies: ["ExpanderEngine"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
