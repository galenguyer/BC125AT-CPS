// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BC125ATKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BC125ATKit", targets: ["BC125ATKit"]),
        .executable(name: "bc125at-cli", targets: ["bc125at-cli"]),
    ],
    targets: [
        .target(
            name: "CBC125ATUSB",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "BC125ATKit", dependencies: ["CBC125ATUSB"]),
        .executableTarget(name: "bc125at-cli", dependencies: ["BC125ATKit"]),
        .testTarget(name: "BC125ATKitTests", dependencies: ["BC125ATKit"], resources: [.copy("Fixtures")]),
    ]
)
