// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentTeam",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentTeamCore", targets: ["AgentTeamCore"])],
    targets: [
        .target(name: "AgentTeamCore"),
        .executableTarget(name: "AgentTeamApp", dependencies: ["AgentTeamCore"]),
        .executableTarget(name: "agentteam", dependencies: ["AgentTeamCore"]),
        .executableTarget(name: "AgentTeamChecks", dependencies: ["AgentTeamCore"]),
    ]
)
