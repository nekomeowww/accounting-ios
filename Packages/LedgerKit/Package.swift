// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "LedgerDomain", targets: ["LedgerDomain"]),
        .library(name: "LedgerPersistence", targets: ["LedgerPersistence"]),
        .library(name: "AgentClient", targets: ["AgentClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "LedgerDomain"),
        .target(
            name: "LedgerPersistence",
            dependencies: [
                "LedgerDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "AgentClient"),
        .testTarget(name: "LedgerDomainTests", dependencies: ["LedgerDomain"]),
        .testTarget(name: "LedgerPersistenceTests", dependencies: ["LedgerPersistence"]),
    ]
)
