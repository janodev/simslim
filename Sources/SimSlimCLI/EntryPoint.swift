import ArgumentParser

@main
struct SimSlimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simslim",
        abstract: "Reduce iOS Simulator background-service overhead."
    )

    mutating func run() async throws {}
}
