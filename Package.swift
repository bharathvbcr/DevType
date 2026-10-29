// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevType",
    // Required by SwiftPM once a target carries .lproj resources (ExpanderEngine's string tables).
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DevType",
            targets: ["DevTypeApp"]
        ),
        // Agent and script command. The binary is `devtype-cli`, not `devtype`:
        // packaging searches for a path ending in `DevType`, and the volume is
        // case-insensitive.
        .executable(
            name: "devtype-cli",
            targets: ["DevTypeCLIApp"]
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
                .product(name: "Yams", package: "Yams"),
                // Only for the legacy-keychain trampolines: Swift cannot suppress a
                // per-call deprecation warning and ObjC can. See DevTypeSafety.h.
                "DevTypeSafety"
            ],
            // UI string tables, one .strings file per table under <lang>.lproj. Loaded explicitly per
            // language by LocalizationTables; Scripts/package-app.sh ships the resulting bundle.
            resources: [
                .process("Localization/Resources")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security")
            ]
        ),
        // ObjC-only: the `@try/@catch` trampoline Swift cannot express. See
        // Sources/DevTypeSafety/include/DevTypeSafety.h.
        .target(
            name: "DevTypeSafety",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        // Every window, controller and panel. A library rather than part of the
        // executable so `DevTypeAppTests` can `@testable import` it — an
        // executableTarget cannot be imported by a test target.
        .target(
            name: "DevTypeAppCore",
            dependencies: ["ExpanderEngine", "DevTypeSafety"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        // Entry point only (main.swift). Keeping the target name `DevTypeApp` and
        // the product name `DevType` keeps `Scripts/package-app.sh` and the bundle's
        // CFBundleExecutable unchanged.
        .executableTarget(
            name: "DevTypeApp",
            dependencies: ["DevTypeAppCore"]
        ),
        // Developer tooling, not shipped: the pure half of the live Safari harness (case table,
        // preflight, key plans, abort and focus-safety rules, verdicts, report). A library so
        // `SafariHarnessCoreTests` can import it; the executable below owns every side effect.
        .target(
            name: "SafariHarnessCore",
            dependencies: ["ExpanderEngine"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        // `Scripts/safari-harness.sh`. Drives the installed DevType.app in a real Safari; the
        // user launches it, it never runs in CI. Not part of the app bundle.
        .executableTarget(
            name: "SafariHarness",
            dependencies: ["SafariHarnessCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        ),
        // Agent-facing command over the real library and macro renderer. A library so
        // `DevTypeCLITests` can call it without spawning the executable.
        .target(
            name: "DevTypeCLI",
            dependencies: ["ExpanderEngine"]
        ),
        .executableTarget(
            name: "DevTypeCLIApp",
            dependencies: ["DevTypeCLI"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security")
            ]
        ),
        // Test support, not product code: the single reader source-contract tests use so a contract
        // covers a whole `Type.swift` + `Type+*.swift` family. Test targets cannot share a file.
        .target(
            name: "SourceTreeTestSupport",
            path: "Tests/SourceTreeTestSupport"
        ),
        .testTarget(
            name: "ExpanderEngineTests",
            dependencies: ["ExpanderEngine", "SourceTreeTestSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        // ObjC-only: SwiftPM rejects mixed-language targets, and a Swift
        // NSWindow subclass that raises aborts before `@catch` can run.
        // The class name stays `DevTypeSafetyTestsRaisingWindow` so the
        // DevTypeSafetyTests filter selects it.
        .testTarget(
            name: "DevTypeSafetyOrderFrontTests",
            dependencies: ["DevTypeSafety"]
        ),
        .testTarget(
            name: "DevTypeAppTests",
            dependencies: ["DevTypeAppCore", "SourceTreeTestSupport"]
        ),
        .testTarget(
            name: "SafariHarnessCoreTests",
            dependencies: ["SafariHarnessCore", "SourceTreeTestSupport"]
        ),
        .testTarget(
            name: "DevTypeCLITests",
            dependencies: ["DevTypeCLI"]
        )
    ]
)
