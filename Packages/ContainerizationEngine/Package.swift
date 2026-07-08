// swift-tools-version:6.0
import PackageDescription

// Low-level Hypervisor.framework VM engine for Dory. The shipped local runtime must build on macOS
// 14, so the macOS 15-only Apple Containerization experiments are kept out of this manifest.
let package = Package(
    name: "ContainerizationEngine",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dory-hv", targets: ["dory-hv"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DoryHVUSBShim",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .target(
            name: "DoryHV",
            dependencies: ["DoryHVUSBShim"],
            linkerSettings: [
                .linkedFramework("Hypervisor"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(
            name: "dory-hv",
            dependencies: [
                "DoryHV",
            ]
        ),
        .testTarget(
            name: "DoryHVTests",
            dependencies: ["DoryHV"]
        ),
    ]
)
