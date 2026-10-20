import Foundation

/// One run of a command line tool: what to start, with what, where.
public struct ProcessInvocation: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Written to its stdin, which is then closed. The conversation goes here, not into the arguments
    /// (any program on the Mac can read those with `ps`).
    public var input: Data
    public var environment: [String: String]
    public var workingDirectory: URL
    public var timeout: TimeInterval

    public init(executable: URL, arguments: [String], input: Data, environment: [String: String],
                workingDirectory: URL, timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.input = input
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public struct ProcessOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case couldNotStart
    case timedOut
}

/// Runs a command line tool to the end. The app starts real processes; tests answer with a fake, so no
/// CLI is ever run and nothing is uploaded.
public protocol ProcessRunner: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.couldNotStart
        }
        // Read both pipes while it runs, so a full pipe never stalls it.
        async let out = Self.readToEnd(stdout.fileHandleForReading)
        async let err = Self.readToEnd(stderr.fileHandleForReading)
        let timedOut = Flag()
        let timer = Task { [process] in
            try await Task.sleep(for: .seconds(invocation.timeout))
            timedOut.set()
            process.terminate()
        }
        // A tool that quits without reading its input must not take Hintlet down with a SIGPIPE.
        let input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        Task.detached {
            try? input.write(contentsOf: invocation.input)
            try? input.close()
        }
        await withTaskCancellationHandler {
            for await _ in finished {}
        } onCancel: { [process] in
            process.terminate()
        }
        timer.cancel()
        // Cancelled: the wait above ended before the process did, and its status isn't there yet to read.
        if process.isRunning {
            try Task.checkCancellation()
            process.waitUntilExit()
        }
        let output = ProcessOutput(status: process.terminationStatus, stdout: await out, stderr: await err)
        if timedOut.isSet { throw ProcessRunnerError.timedOut }
        try Task.checkCancellation()
        return output
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Where the CLIs usually are. A GUI app doesn't get the shell's PATH, so this looks in the usual places
/// itself; the user can point at another one in the settings.
public enum CommandLocator {
    public static func locate(_ tool: SummaryTool, chosen: String?, home: URL,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let paths = [chosen].compactMap { $0 } + candidates(for: tool, home: home.path)
        return paths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func candidates(for tool: SummaryTool, home: String) -> [String] {
        switch tool {
        case .claudeCode:
            ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
             "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        case .codex:
            ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
             "\(home)/.bun/bin/codex",
             // Bundled with the ChatGPT app (and the Codex app), signed in through ~/.codex like the CLI.
             "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
             "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
             "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
             "/Applications/Codex.app/Contents/Resources/codex"]
        }
    }
}

/// What both account backends share: running the CLI in an empty folder, with the environment of a
/// signed-in user rather than of an API key or of a Claude Code session Hintlet happened to be started from.
enum AccountCLI {
    static let timeout: TimeInterval = 180

    /// Variables that would make the CLI use an API key instead of the account, or think it runs inside
    /// another Claude Code session.
    private static let dropped: Set = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "CLAUDECODE"]

    static func environment(from inherited: [String: String], for executable: URL) -> [String: String] {
        var env = inherited.filter { !dropped.contains($0.key) && !$0.key.hasPrefix("CLAUDE_CODE_") }
        let usual = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (usual + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    static func run(_ tool: SummaryTool, executable: URL?, arguments: [String], input: String, runner: any ProcessRunner,
                    workingDirectory: URL, environment: [String: String]) async throws -> ProcessOutput {
        guard let executable else { throw SummaryFailure.toolNotFound(tool) }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        do {
            return try await runner.run(ProcessInvocation(
                executable: executable, arguments: arguments, input: Data(input.utf8),
                environment: Self.environment(from: environment, for: executable),
                workingDirectory: workingDirectory, timeout: timeout))
        } catch ProcessRunnerError.couldNotStart {
            throw SummaryFailure.toolNotFound(tool)
        } catch ProcessRunnerError.timedOut {
            throw SummaryFailure.timedOut
        }
    }

    /// What went wrong, from the words the CLI used.
    static func failure(_ tool: SummaryTool, message: String) -> any Error {
        let text = message.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("prompt is too long", "context_length_exceeded", "context window", "input is too long") {
            return SummaryModelError.promptTooLong
        }
        if has("not logged in", "/login", "codex login", "invalid api key", "oauth", "401", "unauthorized", "please log in") {
            return SummaryFailure.notSignedIn(tool)
        }
        if has("usage limit", "hit your limit", "rate limit", "limit reached", "429") { return SummaryFailure.rateLimited }
        if has("overloaded", "529", "api error: 5", "503", "500 internal") { return SummaryFailure.serviceUnavailable }
        if has("connection error", "network", "enotfound", "fetch failed", "stream disconnected", "error sending request", "timed out") {
            return SummaryFailure.offline
        }
        return SummaryFailure.toolFailed(tool)
    }

    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Claude through the Claude Code CLI the user signed in to (`claude -p`), on their Claude plan: no key.
/// What it is given is uploaded to Anthropic; the app only uses it after the user agreed to that.
public struct ClaudeCodeSummaryModel: SummaryModel {
    private let executable: URL?
    private let runner: any ProcessRunner
    private let workingDirectory: URL
    private let environment: [String: String]

    public init(executable: URL?, runner: any ProcessRunner = FoundationProcessRunner(), workingDirectory: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.runner = runner
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public var backend: SummaryBackend { .claudeAccount }
    public var promptBudget: Int { 60_000 }

    public func respond(instructions: String, prompt: String) async throws -> String {
        let output = try await AccountCLI.run(.claudeCode, executable: executable, arguments: [
            "-p",
            "--output-format", "json",
            "--system-prompt", instructions,
            // A summary needs no tools, skills, MCP servers or the user's hooks, and leaves no session behind
            // (it would show up among the user's Claude Code sessions).
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#,
            "--no-session-persistence",
        ], input: prompt, runner: runner, workingDirectory: workingDirectory, environment: environment)
        let reply = try? JSONDecoder().decode(Reply.self, from: output.stdout)
        if let reply {
            if reply.isError == true || output.status != 0 {
                throw AccountCLI.failure(.claudeCode, message: reply.result ?? AccountCLI.text(output.stderr))
            }
            let text = (reply.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw SummaryFailure.unreadableResponse }
            return text
        }
        let text = AccountCLI.text(output.stdout)
        guard output.status == 0 else {
            throw AccountCLI.failure(.claudeCode, message: text + "\n" + AccountCLI.text(output.stderr))
        }
        guard !text.isEmpty else { throw SummaryFailure.unreadableResponse }
        return text
    }

    private struct Reply: Decodable {
        let result: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case result
            case isError = "is_error"
        }
    }
}

/// OpenAI's models through the Codex CLI the user signed in to (`codex exec`), on their ChatGPT plan: no
/// key. What it is given is uploaded to OpenAI; the app only uses it after the user agreed to that.
public struct CodexSummaryModel: SummaryModel {
    private let executable: URL?
    private let runner: any ProcessRunner
    private let workingDirectory: URL
    private let environment: [String: String]

    public init(executable: URL?, runner: any ProcessRunner = FoundationProcessRunner(), workingDirectory: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.runner = runner
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public var backend: SummaryBackend { .codexAccount }
    public var promptBudget: Int { 60_000 }

    public func respond(instructions: String, prompt: String) async throws -> String {
        let answer = workingDirectory.appendingPathComponent("codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: answer) }
        let output = try await AccountCLI.run(.codex, executable: executable, arguments: [
            "exec",
            // No session left behind, none of the user's config, MCP servers or rules, and nothing it may change.
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "--cd", workingDirectory.path,
            "--output-last-message", answer.path,
            "-",
        ], input: instructions + "\n只回覆這三行，不要執行任何指令或讀取檔案。\n\n" + prompt,
           runner: runner, workingDirectory: workingDirectory, environment: environment)
        guard output.status == 0 else {
            throw AccountCLI.failure(.codex, message: AccountCLI.text(output.stderr) + "\n" + AccountCLI.text(output.stdout))
        }
        let written = (try? Data(contentsOf: answer)).map(AccountCLI.text) ?? ""
        let text = written.isEmpty ? AccountCLI.text(output.stdout) : written
        guard !text.isEmpty else { throw SummaryFailure.unreadableResponse }
        return text
    }
}
