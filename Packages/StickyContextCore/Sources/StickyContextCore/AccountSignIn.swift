import Foundation

/// Whether the user's Claude or Codex account can write AI notes here.
public enum AccountState: Equatable, Sendable {
    /// The CLI isn't where Hintlet looks.
    case notInstalled
    case signedOut
    /// With the account's email, when the CLI tells it.
    case signedIn(String?)
    /// The CLI didn't answer in a way Hintlet understands.
    case unknown
}

/// Asks the CLI whether the user is signed in, and signs them in through it: both CLIs open the browser
/// and wait for the user to finish there (`claude auth login`, `codex login`). Nothing else is run.
public struct AccountSignIn: Sendable {
    public let tool: SummaryTool
    private let executable: URL?
    private let runner: any ProcessRunner
    private let environment: [String: String]
    private let workingDirectory: URL
    /// Long enough to sign in in the browser.
    static let signInTimeout: TimeInterval = 300
    static let statusTimeout: TimeInterval = 20

    public init(tool: SummaryTool, executable: URL?, runner: any ProcessRunner = FoundationProcessRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment, workingDirectory: URL) {
        self.tool = tool
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func state() async -> AccountState {
        let arguments = tool == .claudeCode ? ["auth", "status", "--json"] : ["login", "status"]
        guard let output = await run(arguments, timeout: Self.statusTimeout) else {
            return executable == nil ? .notInstalled : .unknown
        }
        return Self.state(of: tool, output)
    }

    /// Returns what the account is afterwards.
    public func signIn() async -> AccountState {
        let arguments = tool == .claudeCode ? ["auth", "login", "--claudeai"] : ["login"]
        guard await run(arguments, timeout: Self.signInTimeout) != nil else {
            return executable == nil ? .notInstalled : await state()
        }
        return await state()
    }

    static func state(of tool: SummaryTool, _ output: ProcessOutput) -> AccountState {
        let text = AccountCLI.text(output.stdout) + "\n" + AccountCLI.text(output.stderr)
        switch tool {
        case .claudeCode:
            struct Status: Decodable {
                let loggedIn: Bool
                let email: String?
            }
            guard let status = try? JSONDecoder().decode(Status.self, from: output.stdout) else {
                return text.lowercased().contains("not logged in") ? .signedOut : .unknown
            }
            return status.loggedIn ? .signedIn(status.email) : .signedOut
        case .codex:
            let lower = text.lowercased()
            if lower.contains("not logged in") { return .signedOut }
            return output.status == 0 && lower.contains("logged in") ? .signedIn(nil) : .signedOut
        }
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async -> ProcessOutput? {
        guard let executable else { return nil }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return try? await runner.run(ProcessInvocation(
            executable: executable, arguments: arguments, input: Data(),
            environment: AccountCLI.environment(from: environment, for: executable),
            workingDirectory: workingDirectory, timeout: timeout))
    }
}
