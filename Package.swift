// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenSensei",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenSensei", targets: ["OpenSensei"])],
    targets: [.target(name: "SMCCore", linkerSettings: [.linkedFramework("IOKit")]),
              .executableTarget(name: "FanHelper", dependencies: ["SMCCore"]),
              .executableTarget(name: "OpenSensei", dependencies: ["SMCCore"]),
              .testTarget(name: "OpenSenseiTests", dependencies: ["OpenSensei"], path: "Tests")]
)
