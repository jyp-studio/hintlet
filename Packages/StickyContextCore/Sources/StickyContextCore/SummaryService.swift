import Foundation

/// Writes an AI note's three lines from a conversation. Swappable: the on-device model first, the Claude
/// API later (ticket 16). Knows nothing of notes, windows or files: it gets the content it is allowed to
/// see and hands back a summary.
public protocol SummaryService: Sendable {
    var backend: SummaryBackend { get }
    /// `previous` is the note's last summary (the prompted service leaves it out, see `SummaryPrompt`).
    func summarize(_ content: ConversationContent, previous: AISummary?) async throws -> AISummary
}

/// A language model that answers a prompt with text: the one thing a backend has to provide.
public protocol SummaryModel: Sendable {
    var backend: SummaryBackend { get }
    /// About how many characters of prompt the model takes, with room left for the instructions and its answer.
    var promptBudget: Int { get }
    func respond(instructions: String, prompt: String) async throws -> String
}

/// What a model can report back for the service to handle.
public enum SummaryModelError: Error, Equatable, Sendable {
    /// The prompt didn't fit; the service tries once more with half as much.
    case promptTooLong
}

public enum SummaryError: Error, Equatable, Sendable {
    /// The model didn't answer in three lines.
    case malformedReply
}

/// The summary service for any model that answers text prompts: builds the prompt within the model's
/// budget and reads the three lines out of its reply.
public struct PromptedSummaryService<Model: SummaryModel>: SummaryService {
    public let model: Model
    private let now: @Sendable () -> Date

    public init(model: Model, now: @escaping @Sendable () -> Date = Date.init) {
        self.model = model
        self.now = now
    }

    public var backend: SummaryBackend { model.backend }

    public func summarize(_ content: ConversationContent, previous: AISummary?) async throws -> AISummary {
        guard !content.messages.isEmpty, content.coverage != .insufficient else {
            // Nothing to go on: say so rather than ask the model to make something up.
            return AISummary(doing: "", stoppedAt: "", next: "", coverage: .insufficient, backend: backend,
                             updatedAt: now(), sourceRevision: content.revision)
        }
        let instructions = SummaryPrompt.instructions(for: content.coverage)
        var budget = model.promptBudget
        let reply: String
        do {
            reply = try await model.respond(instructions: instructions,
                                            prompt: SummaryPrompt.prompt(for: content, budget: budget, previousGoal: previous?.goal))
        } catch SummaryModelError.promptTooLong {
            budget /= 2
            reply = try await model.respond(instructions: instructions,
                                            prompt: SummaryPrompt.prompt(for: content, budget: budget, previousGoal: previous?.goal))
        }
        guard let lines = SummaryPrompt.lines(in: reply) else { throw SummaryError.malformedReply }
        return AISummary(goal: lines.goal, point: lines.point, next: lines.next ?? "", coverage: content.coverage,
                         backend: backend, updatedAt: now(), sourceRevision: content.revision)
    }
}

/// The words sent to the model, and reading its answer.
enum SummaryPrompt {
    static func instructions(for coverage: SummaryCoverage) -> String {
        var text = """
        你替使用者寫一張便利貼，貼在他和 Claude 的一段對話上。他同時做好幾件事，從別的工作切回這個對話時只會掃一眼：要讓他立刻抓到重點、知道該看什麼，不必往上翻對話。只根據提供的內容，不要推測沒看到的部分。
        回覆兩到三行，不要其他文字：
        目標：這段對話整體要達成的事，動詞加對象，16 字以內，不加句號。
        重點：最新進展的內容本身，30 字以內，不加句號。寫結論、結果、找到的原因、做出的決定、關鍵數字或檔名。
        下一步：使用者接下來要看或要做的事，開頭用「等你」「卡住」「進行中」其中一個加冒號，20 字以內，不加句號。Claude 已經做完、沒有要使用者做的事時，省略這一行。
        重點直接寫內容，不要寫「回答了」「說明了」「討論了」「整理了」「提供了」「完成了」這類只描述動作的字，使用者看了還是不知道結果是什麼。
        （不好）重點：回答了磁碟空間的問題
        （好）重點：磁碟正常；I/O 錯誤是 Google Drive 在備份 ~/dev
        （好）下一步：等你：在 Google Drive 排除 ~/dev
        （不好）重點：完成了按鈕的修改
        （好）重點：動態島按鈕與顏色點都改成 26pt
        目標要穩定：一個目標底下的小步驟、中途插進來的無關小問題，都不改目標，重點寫最新那一步或那個插曲的結論。只有使用者明確開始一件跟之前無關的新工作，才換成新的目標。提示裡有上一張便利貼的目標時，沒有開始新工作就沿用它。
        「下一步」怎麼選：Claude 在問使用者、等他決定或測試，用「等你」並寫出要他做什麼；遇到錯誤做不下去用「卡住」並寫錯誤本身；Claude 還沒回完用「進行中」並寫它正在做的事。
        用對話所用的語言回答，中文請用繁體；英文時三行改用 Goal: / Key point: / Next:，下一步用 Your turn / Stuck / In progress。
        """
        if case .partial(let count) = coverage {
            text += "\n內容只是對話的一部分（已載入的 \(count) 則訊息），沒看到的部分不要推測，也不要補寫。"
        }
        return text
    }

    /// The longest a single message may take in the prompt.
    static let messageLimit = 400
    /// The newest message may take more: where the conversation stopped is in it.
    static let latestMessageLimit = 1200

    /// Within `budget` characters: the newest exchange first (where the conversation is now, even after
    /// a change of topic), then as many earlier messages as fit, then the first request as background.
    /// The last summary is left out: a small model copies it, and stays on an old topic.
    static func prompt(for content: ConversationContent, budget: Int, previousGoal: String? = nil) -> String {
        let source = switch content.coverage {
        case .partial(let count): "僅根據已載入的 \(count) 則訊息"
        default: "完整對話紀錄的節錄"
        }
        let messages = content.messages
        let latestQuestion = messages.lastIndex { $0.role == .user }
        let latestReply = messages.indices.last.flatMap { last in messages[last].role == .assistant ? last : nil }
        var head = "以下是一段 Claude 對話（\(source)）。\n"
        if let latestQuestion {
            head += "\n最新的使用者訊息：\n" + clipped(messages[latestQuestion].text, to: messageLimit) + "\n"
        }
        if let latestReply {
            head += "\nClaude 的最新回覆：\n" + clipped(messages[latestReply].text, to: min(latestMessageLimit, max(budget / 3, 40))) + "\n"
        }
        let goal = messages.firstIndex { $0.role == .user }.flatMap { $0 == latestQuestion ? nil : $0 }
        var background = ""
        if let goal {
            background += "\n最初的要求（只作背景）：\n" + clipped(messages[goal].text, to: max(budget / 8, 40)) + "\n"
        }
        let kept = previousGoal.flatMap { $0.isEmpty ? nil : "\n上一張便利貼的目標（沒有開始新工作就沿用）：" + $0 + "\n" } ?? ""
        let tail = kept + "\n請寫出目標、重點，有需要時再加下一步。"
        let earlierHeading = "\n之前的訊息（由舊到新）：\n"
        var room = budget - head.count - background.count - tail.count - earlierHeading.count
        var earlier: [String] = []
        let shown: Set = [latestQuestion, latestReply, goal].compactMap { $0 }.reduce(into: Set<Int>()) { $0.insert($1) }
        for index in messages.indices.reversed() where !shown.contains(index) {
            let message = messages[index]
            let line = (message.role == .user ? "使用者：" : "Claude：") + clipped(message.text, to: messageLimit) + "\n"
            guard line.count <= room else { break }
            earlier.append(line)
            room -= line.count
        }
        let earlierPart = earlier.isEmpty ? "" : earlierHeading + earlier.reversed().joined()
        return String((head + earlierPart + background + tail).prefix(budget))
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    /// What each line may be labelled: the goal, the key point, the next step; older answers' labels too.
    private static let labels: [[String]] = [
        ["目標", "Goal", "正在做什麼", "在做什麼", "Doing", "What it's doing"],
        ["重點", "Key point", "Point", "現況", "Status", "停在哪裡", "停在哪", "Stopped at", "Where it stopped"],
        ["下一步", "Next step", "Next"],
    ]

    /// The goal, key point and (when there is one) next step of a reply: by their labels where it has
    /// them, the other lines in order filling in the rest (models label one line and not another).
    static func lines(in reply: String) -> (goal: String, point: String, next: String?)? {
        let lines = reply.split(whereSeparator: \.isNewline).map(cleaned).filter { !$0.isEmpty }
        var labelled: [String?] = [nil, nil, nil]
        var unlabelled: [String] = []
        for line in lines {
            if let (slot, value) = labelledValue(of: line) {
                if labelled[slot] == nil, !value.isEmpty { labelled[slot] = trimmedEnd(value) }
            } else if !(line.hasSuffix("：") || line.hasSuffix(":")) {
                unlabelled.append(trimmedEnd(line))
            }
        }
        var rest = unlabelled[...]
        guard let goal = labelled[0] ?? rest.popFirst(), let point = labelled[1] ?? rest.popFirst() else { return nil }
        let next = labelled[2] ?? rest.popFirst()
        return (goal, point, next.flatMap { ["無", "none", "-"].contains($0.lowercased()) ? nil : $0 })
    }

    /// A short line needs no full stop.
    private static func trimmedEnd(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "。．.").union(.whitespaces))
    }

    /// Without bullets, numbering and bold.
    private static func cleaned(_ line: Substring) -> String {
        var text = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if let first = text.first, "-*•・".contains(first) { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let match = text.firstMatch(of: /^\d+[.)、]\s*/) { text = String(text[match.range.upperBound...]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func labelledValue(of line: String) -> (Int, String)? {
        for (slot, names) in labels.enumerated() {
            for name in names where line.lowercased().hasPrefix(name.lowercased()) {
                let rest = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                guard let colon = rest.first, colon == ":" || colon == "：" else { continue }
                return (slot, rest.dropFirst().trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
