import Foundation
import Testing
import StickyContextCore

/// Answers every run with what the test says, and keeps what was asked. Nothing is ever started.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    var status: Int32 = 0
    var stdout = ""
    var stderr = ""
    var failure: (any Error)?
    /// Codex writes its answer to the file after `--output-last-message`; this is what the fake writes there.
    var lastMessage: String?
    private(set) var runs: [ProcessInvocation] = []

    func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput {
        runs.append(invocation)
        if let failure { throw failure }
        if let lastMessage, let flag = invocation.arguments.firstIndex(of: "--output-last-message"),
           invocation.arguments.indices.contains(flag + 1) {
            try Data(lastMessage.utf8).write(to: URL(fileURLWithPath: invocation.arguments[flag + 1]))
        }
        return ProcessOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    func claudeReply(_ text: String, isError: Bool = false) {
        status = isError ? 1 : 0
        stdout = String(decoding: try! JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": isError ? "error" : "success", "is_error": isError, "result": text,
            "session_id": "00000000-0000-0000-0000-000000000000",
        ]), as: UTF8.self)
    }

    var lastInput: String { String(decoding: runs.last?.input ?? Data(), as: UTF8.self) }
}

private let claudeBinary = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
private let codexBinary = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
private let conversation = "使用者：幫我重構登入流程 sk-private-detail"

private func scratchFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AccountCLITests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func claude(_ runner: FakeProcessRunner, executable: URL? = claudeBinary,
                    environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"]) -> ClaudeCodeSummaryModel {
    ClaudeCodeSummaryModel(executable: executable, runner: runner, workingDirectory: scratchFolder(), environment: environment)
}

private func codex(_ runner: FakeProcessRunner, executable: URL? = codexBinary,
                   environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"]) -> CodexSummaryModel {
    CodexSummaryModel(executable: executable, runner: runner, workingDirectory: scratchFolder(), environment: environment)
}

@Suite("Claude 帳號（Claude Code CLI）：怎麼執行")
struct ClaudeCodeInvocation {
    @Test("以 claude -p 執行：JSON 輸出、沒有工具、不留 session、不跑 hook，指示放在 system prompt")
    func arguments() async throws {
        let runner = FakeProcessRunner()
        runner.claudeReply("正在做什麼：a\n停在哪裡：b\n下一步：c")

        _ = try await claude(runner).respond(instructions: "寫三行", prompt: conversation)

        let run = try #require(runner.runs.first)
        #expect(run.executable == claudeBinary)
        let args = run.arguments
        #expect(args.first == "-p")
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.value(after: "--output-format") == "json")
        #expect(args.value(after: "--tools") == "")
        #expect(args.value(after: "--system-prompt") == "寫三行")
        let settings = try #require(args.value(after: "--settings"))
        #expect(settings.contains("\"disableAllHooks\":true"))
    }

    @Test("對話內容從 stdin 給，不放在指令參數裡（別的程式用 ps 看得到參數）")
    func promptOnStdin() async throws {
        let runner = FakeProcessRunner()
        runner.claudeReply("x\ny\nz")

        _ = try await claude(runner).respond(instructions: "寫三行", prompt: conversation)

        #expect(runner.lastInput == conversation)
        #expect(runner.runs.first?.arguments.joined(separator: " ").range(of: "sk-private-detail") == nil)
    }

    @Test("用登入的帳號：拿掉會讓它改用 API key 的變數，也拿掉從 Claude Code 繼承來的 session 變數")
    func environment() async throws {
        let runner = FakeProcessRunner()
        runner.claudeReply("x\ny\nz")
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "ANTHROPIC_API_KEY": "sk-ant-x",
                         "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
                         "CLAUDE_CODE_ENTRYPOINT": "cli", "LANG": "zh_TW.UTF-8"]

        _ = try await claude(runner, environment: inherited).respond(instructions: "i", prompt: "p")

        let env = try #require(runner.runs.first?.environment)
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT"] {
            #expect(env[name] == nil, "\(name) passed on")
        }
        #expect(env["HOME"] == "/Users/test")
        #expect(env["LANG"] == "zh_TW.UTF-8")
        // A GUI app's PATH is short: the CLI's own folder and Homebrew's come first.
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("/usr/bin"))
    }

    @Test("在一個空的資料夾裡執行，不會讀到任何專案的 CLAUDE.md")
    func workingDirectory() async throws {
        let runner = FakeProcessRunner()
        runner.claudeReply("x\ny\nz")
        let folder = scratchFolder()

        _ = try await ClaudeCodeSummaryModel(executable: claudeBinary, runner: runner, workingDirectory: folder,
                                             environment: [:]).respond(instructions: "i", prompt: "p")

        #expect(runner.runs.first?.workingDirectory == folder)
        #expect((runner.runs.first?.timeout ?? 0) > 0)
    }

    @Test("讀出 JSON 裡的 result；不是 JSON 時用整段輸出")
    func readsResult() async throws {
        let runner = FakeProcessRunner()
        runner.claudeReply("正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
        #expect(try await claude(runner).respond(instructions: "i", prompt: "p") == "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")

        runner.stdout = "第一行\n第二行\n第三行\n"
        #expect(try await claude(runner).respond(instructions: "i", prompt: "p") == "第一行\n第二行\n第三行")
    }

    @Test("後端是 Claude 帳號")
    func backend() {
        let model = claude(FakeProcessRunner())
        #expect(model.backend == .claudeAccount)
        #expect(model.promptBudget >= 20_000)
    }
}

@Suite("Claude 帳號（Claude Code CLI）：失敗")
struct ClaudeCodeFailures {
    @Test("找不到 claude 就不執行")
    func notFound() async {
        let runner = FakeProcessRunner()
        await #expect(throws: SummaryFailure.toolNotFound(.claudeCode)) {
            _ = try await claude(runner, executable: nil).respond(instructions: "i", prompt: "p")
        }
        #expect(runner.runs.isEmpty)
    }

    @Test("啟動不了也算找不到")
    func couldNotStart() async {
        let runner = FakeProcessRunner()
        runner.failure = ProcessRunnerError.couldNotStart
        await #expect(throws: SummaryFailure.toolNotFound(.claudeCode)) {
            _ = try await claude(runner).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("沒登入：請使用者先在終端機登入")
    func notSignedIn() async {
        for message in ["Not logged in · Please run /login", "Invalid API key · Please run /login",
                        "OAuth token has expired. Please obtain a new token or refresh your existing token."] {
            let runner = FakeProcessRunner()
            runner.claudeReply(message, isError: true)
            await #expect(throws: SummaryFailure.notSignedIn(.claudeCode)) {
                _ = try await claude(runner).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("帳號用量達上限")
    func usageLimit() async {
        for message in ["Claude AI usage limit reached|1760000000", "You've hit your limit · resets 3pm"] {
            let runner = FakeProcessRunner()
            runner.claudeReply(message, isError: true)
            await #expect(throws: SummaryFailure.rateLimited) {
                _ = try await claude(runner).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("Prompt is too long：交給摘要服務縮短再試")
    func tooLong() async {
        let runner = FakeProcessRunner()
        runner.claudeReply("Prompt is too long", isError: true)
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await claude(runner).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("連不上網路、服務忙線")
    func networkAndOverload() async {
        let offline = FakeProcessRunner()
        offline.claudeReply("API Error: Connection error.", isError: true)
        await #expect(throws: SummaryFailure.offline) {
            _ = try await claude(offline).respond(instructions: "i", prompt: "p")
        }
        let busy = FakeProcessRunner()
        busy.claudeReply("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}", isError: true)
        await #expect(throws: SummaryFailure.serviceUnavailable) {
            _ = try await claude(busy).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("太久沒回：逾時")
    func timeout() async {
        let runner = FakeProcessRunner()
        runner.failure = ProcessRunnerError.timedOut
        await #expect(throws: SummaryFailure.timedOut) {
            _ = try await claude(runner).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("其他失敗：說是 Claude Code 出錯")
    func otherFailure() async {
        let runner = FakeProcessRunner()
        runner.status = 2
        runner.stdout = ""
        runner.stderr = "error: unknown option '--whatever'"
        await #expect(throws: SummaryFailure.toolFailed(.claudeCode)) {
            _ = try await claude(runner).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("成功但沒有文字：看不懂的回覆")
    func emptyResult() async {
        let runner = FakeProcessRunner()
        runner.claudeReply("  ")
        await #expect(throws: SummaryFailure.unreadableResponse) {
            _ = try await claude(runner).respond(instructions: "i", prompt: "p")
        }
    }
}

@Suite("Codex 帳號（Codex CLI）：怎麼執行")
struct CodexInvocation {
    @Test("以 codex exec 執行：不留 session、不讀使用者設定與規則、唯讀沙盒、答案寫到暫存檔")
    func arguments() async throws {
        let runner = FakeProcessRunner()
        runner.lastMessage = "正在做什麼：a\n停在哪裡：b\n下一步：c"

        _ = try await codex(runner).respond(instructions: "寫三行", prompt: conversation)

        let run = try #require(runner.runs.first)
        #expect(run.executable == codexBinary)
        let args = run.arguments
        #expect(args.first == "exec")
        for flag in ["--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(args.value(after: "--sandbox") == "read-only")
        #expect(args.value(after: "--color") == "never")
        #expect(args.value(after: "--cd") == run.workingDirectory.path)
        #expect(args.last == "-")
    }

    @Test("指示與對話內容都從 stdin 給，不放在參數裡")
    func promptOnStdin() async throws {
        let runner = FakeProcessRunner()
        runner.lastMessage = "x\ny\nz"

        _ = try await codex(runner).respond(instructions: "寫三行", prompt: conversation)

        #expect(runner.lastInput.hasPrefix("寫三行"))
        #expect(runner.lastInput.hasSuffix(conversation))
        #expect(runner.runs.first?.arguments.joined(separator: " ").range(of: "sk-private-detail") == nil)
    }

    @Test("讀出最後一則訊息，讀完刪掉暫存檔")
    func readsLastMessage() async throws {
        let runner = FakeProcessRunner()
        runner.lastMessage = "正在做什麼：重構\n停在哪裡：測試\n下一步：送審\n"
        runner.stdout = "progress noise"

        let reply = try await codex(runner).respond(instructions: "i", prompt: "p")

        #expect(reply == "正在做什麼：重構\n停在哪裡：測試\n下一步：送審")
        let args = try #require(runner.runs.first?.arguments)
        let file = try #require(args.value(after: "--output-last-message"))
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("沒有暫存檔時用 stdout")
    func fallsBackToStdout() async throws {
        let runner = FakeProcessRunner()
        runner.stdout = "一\n二\n三\n"
        #expect(try await codex(runner).respond(instructions: "i", prompt: "p") == "一\n二\n三")
    }

    @Test("用登入的帳號：拿掉 OpenAI API key 變數")
    func environment() async throws {
        let runner = FakeProcessRunner()
        runner.lastMessage = "x\ny\nz"

        _ = try await codex(runner, environment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-x", "CODEX_API_KEY": "y",
                                                  "CLAUDE_CODE_CHILD_SESSION": "1"]).respond(instructions: "i", prompt: "p")

        let env = try #require(runner.runs.first?.environment)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["CODEX_API_KEY"] == nil)
        #expect(env["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(env["PATH"]?.hasPrefix(codexBinary.deletingLastPathComponent().path) == true)
    }

    @Test("後端是 Codex 帳號")
    func backend() {
        #expect(codex(FakeProcessRunner()).backend == .codexAccount)
    }
}

@Suite("Codex 帳號（Codex CLI）：失敗")
struct CodexFailures {
    private func failing(_ stderr: String) -> FakeProcessRunner {
        let runner = FakeProcessRunner()
        runner.status = 1
        runner.stderr = stderr
        return runner
    }

    @Test("找不到 codex 就不執行")
    func notFound() async {
        let runner = FakeProcessRunner()
        await #expect(throws: SummaryFailure.toolNotFound(.codex)) {
            _ = try await codex(runner, executable: nil).respond(instructions: "i", prompt: "p")
        }
        #expect(runner.runs.isEmpty)
    }

    @Test("沒登入")
    func notSignedIn() async {
        for message in ["ERROR: unexpected status 401 Unauthorized", "Not logged in. Run `codex login`."] {
            await #expect(throws: SummaryFailure.notSignedIn(.codex)) {
                _ = try await codex(failing(message)).respond(instructions: "i", prompt: "p")
            }
        }
    }

    @Test("用量上限、內容太長、網路、其他")
    func others() async {
        await #expect(throws: SummaryFailure.rateLimited) {
            _ = try await codex(failing("ERROR: You've hit your usage limit. Try again later.")).respond(instructions: "i", prompt: "p")
        }
        await #expect(throws: SummaryModelError.promptTooLong) {
            _ = try await codex(failing("ERROR: context_length_exceeded: input exceeds the context window")).respond(instructions: "i", prompt: "p")
        }
        await #expect(throws: SummaryFailure.offline) {
            _ = try await codex(failing("ERROR: stream disconnected before completion: error sending request")).respond(instructions: "i", prompt: "p")
        }
        await #expect(throws: SummaryFailure.toolFailed(.codex)) {
            _ = try await codex(failing("thread 'main' panicked")).respond(instructions: "i", prompt: "p")
        }
    }

    @Test("成功但什麼也沒寫：看不懂的回覆")
    func empty() async {
        await #expect(throws: SummaryFailure.unreadableResponse) {
            _ = try await codex(FakeProcessRunner()).respond(instructions: "i", prompt: "p")
        }
    }
}

@Suite("找 CLI 在哪裡")
struct LocatingCLIs {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test("使用者選的路徑可以執行時優先")
    func chosenFirst() {
        let found = CommandLocator.locate(.codex, chosen: "/opt/tools/codex", home: home,
                                          isExecutable: { ["/opt/tools/codex", "/opt/homebrew/bin/codex"].contains($0) })
        #expect(found?.path == "/opt/tools/codex")
    }

    @Test("選的路徑不能執行時照常找")
    func chosenMissing() {
        let found = CommandLocator.locate(.codex, chosen: "/gone/codex", home: home,
                                          isExecutable: { $0 == "/opt/homebrew/bin/codex" })
        #expect(found?.path == "/opt/homebrew/bin/codex")
    }

    @Test("codex 不在 PATH 上時，找得到 ChatGPT App 裡附的那一份")
    func codexInsideApp() {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let found = CommandLocator.locate(.codex, chosen: nil, home: home, isExecutable: { $0 == bundled })
        #expect(found?.path == bundled)
    }

    @Test("Claude Code 的常見安裝位置")
    func claudeLocations() {
        for path in ["/Users/test/.local/bin/claude", "/Users/test/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            #expect(CommandLocator.locate(.claudeCode, chosen: nil, home: home, isExecutable: { $0 == path })?.path == path)
        }
    }

    @Test("哪裡都找不到就是 nil（設定裡這個選項不能選）")
    func nowhere() {
        #expect(CommandLocator.locate(.claudeCode, chosen: nil, home: home, isExecutable: { _ in false }) == nil)
        #expect(CommandLocator.locate(.codex, chosen: nil, home: home, isExecutable: { _ in false }) == nil)
    }
}

extension Array where Element == String {
    func value(after flag: String) -> String? {
        firstIndex(of: flag).flatMap { index(after: $0) < endIndex ? self[index(after: $0)] : nil }
    }
}

@Suite("執行程式（用系統內建的 cat 與 sleep，不碰任何 CLI 或網路）")
struct RunningProcesses {
    private func invocation(_ path: String, _ arguments: [String] = [], input: String = "", timeout: TimeInterval = 10) -> ProcessInvocation {
        ProcessInvocation(executable: URL(fileURLWithPath: path), arguments: arguments, input: Data(input.utf8),
                          environment: ["PATH": "/usr/bin:/bin"], workingDirectory: FileManager.default.temporaryDirectory,
                          timeout: timeout)
    }

    @Test("stdin 的內容原樣讀得到，回報結束碼")
    func stdin() async throws {
        let output = try await FoundationProcessRunner().run(invocation("/bin/cat", input: "對話內容\n"))
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "對話內容\n")
    }

    @Test("太久沒結束就停掉它，回報逾時")
    func timeout() async {
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await FoundationProcessRunner().run(invocation("/bin/sleep", ["30"], timeout: 0.3))
        }
    }

    @Test("取消時停掉它，不會因為還在跑就讀結束碼而當掉")
    func cancelled() async {
        let run = Task { try await FoundationProcessRunner().run(invocation("/bin/sleep", ["30"], timeout: 30)) }
        try? await Task.sleep(for: .milliseconds(200))
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }

    @Test("檔案不存在：啟動不了")
    func missing() async {
        await #expect(throws: ProcessRunnerError.couldNotStart) {
            _ = try await FoundationProcessRunner().run(invocation("/nonexistent/claude"))
        }
    }
}

@Suite("帳號登入狀態與登入")
struct AccountSignInTests {
    private func signIn(_ tool: SummaryTool, _ runner: FakeProcessRunner, found: Bool = true) -> AccountSignIn {
        AccountSignIn(tool: tool, executable: found ? (tool == .claudeCode ? claudeBinary : codexBinary) : nil,
                      runner: runner, environment: ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-should-not-pass"],
                      workingDirectory: scratchFolder())
    }

    @Test("Claude：auth status 說已登入，帶出 email；不把 API key 傳給 CLI")
    func claudeSignedIn() async {
        let runner = FakeProcessRunner()
        runner.stdout = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com"}"#
        #expect(await signIn(.claudeCode, runner).state() == .signedIn("me@example.com"))
        #expect(runner.runs.last?.arguments == ["auth", "status", "--json"])
        #expect(runner.runs.last?.environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("Claude：沒登入")
    func claudeSignedOut() async {
        let runner = FakeProcessRunner()
        runner.stdout = #"{"loggedIn": false}"#
        #expect(await signIn(.claudeCode, runner).state() == .signedOut)
    }

    @Test("Codex：login status")
    func codexStates() async {
        let runner = FakeProcessRunner()
        runner.stdout = "Logged in using ChatGPT"
        #expect(await signIn(.codex, runner).state() == .signedIn(nil))
        runner.status = 1
        runner.stdout = "Not logged in"
        #expect(await signIn(.codex, runner).state() == .signedOut)
    }

    @Test("找不到 CLI 就是沒安裝，什麼都不執行")
    func notInstalled() async {
        let runner = FakeProcessRunner()
        #expect(await signIn(.claudeCode, runner, found: false).state() == .notInstalled)
        #expect(runner.runs.isEmpty)
    }

    @Test("登入用 CLI 自己的瀏覽器登入，完成後再看一次狀態")
    func signsInThroughTheBrowser() async {
        let runner = FakeProcessRunner()
        runner.stdout = #"{"loggedIn": true}"#
        #expect(await signIn(.claudeCode, runner).signIn() == .signedIn(nil))
        #expect(runner.runs.map(\.arguments) == [["auth", "login", "--claudeai"], ["auth", "status", "--json"]])

        let codexRunner = FakeProcessRunner()
        codexRunner.stdout = "Logged in using ChatGPT"
        _ = await signIn(.codex, codexRunner).signIn()
        #expect(codexRunner.runs.first?.arguments == ["login"])
    }
}
