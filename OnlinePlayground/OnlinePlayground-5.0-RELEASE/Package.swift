// swift-tools-version:5.2
import PackageDescription

let dependencies:[Package.Dependency] = [
    .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", .exact("1.0.0"))
]

var targets:[Target] = [
    .target(name: "OnlinePlayground", dependencies: ["CryptoSwift"]), // Link custom modules here
]

var products: [Product] = [
    .library(name: "OnlinePlayground", type: .static, targets: ["OnlinePlayground"])
]

let package = Package(
    name: "OnlinePlayground",
    products: products,
    dependencies: dependencies,
    targets: targets
)
