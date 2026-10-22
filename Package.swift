// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "V2MacSandbox",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../app/Packages/V2MacCore"),
    ],
    targets: [
        // Shared by the helper and the agent; no Foundation, so the static agent stays small.
        .target(name: "AgentProtocol"),
        // Built only with the Static Linux SDK (Scripts/build-agent.sh); an empty program elsewhere.
        .executableTarget(name: "Agent", dependencies: ["AgentProtocol"]),
        .target(name: "SandboxHelper", dependencies: ["AgentProtocol", "V2MacCore"]),
        .executableTarget(name: "V2MacSandbox", dependencies: ["SandboxHelper"]),
        .testTarget(name: "SandboxTests", dependencies: ["AgentProtocol", "SandboxHelper", "V2MacCore"]),
    ]
)
