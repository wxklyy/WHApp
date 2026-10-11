// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Injector",
    platforms: [.iOS(.v15)],
    targets: [
        .executableTarget(
            name: "Injector",
            path: "Sources"
        )
    ]
)
