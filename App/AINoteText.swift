import AppKit
import HintletCore

/// How an AI note words its summary.
@MainActor
enum AINoteText {
    /// What a summary's lines are: the goal, the key point, the next step.
    static var labels: [String] {
        [String(localized: "目標"), String(localized: "重點"), String(localized: "下一步")]
    }

    /// What the AI note says, as text, for it turned back into an ordinary note.
    static func shownText(_ summary: AISummary) -> String {
        summary.lines.joined(separator: "\n")
    }

    /// Each state at a glance by its shape, in the note's own ink (no colours): its symbol and its name.
    static func look(of state: SummaryState) -> (symbol: String, name: String)? {
        switch state {
        case .working: ("ellipsis.circle", String(localized: "進行中"))
        case .waitingForYou: ("hand.raised", String(localized: "等你"))
        case .stuck: ("exclamationmark.triangle", String(localized: "卡住"))
        case .unknown: nil
        }
    }

    /// The small print under the lines: when it was written, from how much, and what is happening now.
    static func footer(_ ai: DisplayedAI) -> String {
        var parts: [String] = []
        switch ai.status {
        case .updating: parts.append(String(localized: "正在更新…"))
        case .failed(let failure):
            if let reason = failure.map(explain) {
                parts.append(String(localized: "更新失敗（\(reason)），顯示上一次的內容"))
            } else {
                parts.append(String(localized: "更新失敗，顯示上一次的內容"))
            }
        case .idle: break
        }
        if let summary = ai.summary {
            if ai.status != .updating { parts.append(String(localized: "更新於 \(time(summary.updatedAt))")) }
            if case .partial(let count) = summary.coverage {
                parts.append(String(localized: "僅根據已載入的 \(count) 則訊息"))
            }
        }
        return "✨ " + (parts.isEmpty ? [String(localized: "AI 便利貼")] : parts).joined(separator: " · ")
    }

    /// What the paper says while there are no lines to show.
    static func placeholder(_ ai: DisplayedAI) -> String? {
        if let summary = ai.summary {
            return summary.coverage == .insufficient ? String(localized: "對話內容還不夠，之後再記錄脈絡。") : nil
        }
        guard case .failed(let failure) = ai.status else { return String(localized: "正在讀取對話…") }
        if let reason = failure.map(explain) { return String(localized: "無法寫出摘要：\(reason)。") }
        return String(localized: "讀不到這個對話的紀錄。")
    }

    /// Why an update failed, in a few words.
    static func explain(_ failure: SummaryFailure) -> String {
        switch failure {
        case .noAPIKey: String(localized: "尚未在設定中填入 API key")
        case .keyRejected: String(localized: "API key 無效或沒有權限")
        case .rateLimited: String(localized: "用量已達上限")
        case .serviceUnavailable: String(localized: "AI 服務暫時無法使用")
        case .offline: String(localized: "連不上網路")
        case .refused: String(localized: "模型拒絕回答")
        case .unreadableResponse: String(localized: "看不懂 AI 服務的回覆")
        case .toolNotFound(let tool): String(localized: "找不到 \(name(of: tool))，請在設定中選擇它的位置")
        case .notSignedIn(let tool): String(localized: "\(name(of: tool)) 尚未登入，請先在終端機登入")
        case .toolFailed(let tool): String(localized: "\(name(of: tool)) 執行失敗")
        case .timedOut: String(localized: "等太久沒有回應")
        case .requestFailed(let status): String(localized: "API 錯誤 \(status)")
        }
    }

    private static func name(of tool: SummaryTool) -> String {
        switch tool {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The note's text, to take in at a glance: the goal in bold, the key point, then (when something waits
    /// on the user or Claude is still at it) the next step after its state's symbol and name, quieter;
    /// then the small print.
    static func attributed(_ ai: DisplayedAI, ink: NSColor, accent: NSColor? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 6
        let size = NoteTypography.textSize
        let goal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size + 3, weight: .semibold),
                                                   .foregroundColor: ink, .paragraphStyle: style]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: ink, .paragraphStyle: style]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size - 2.5), .foregroundColor: ink.withAlphaComponent(0.5),
                                                    .paragraphStyle: style]
        let text = NSMutableAttributedString()
        if let placeholder = placeholder(ai) {
            text.append(NSAttributedString(string: placeholder + "\n", attributes: body.merging([.foregroundColor: ink.withAlphaComponent(0.6)]) { $1 }))
        } else if let summary = ai.summary {
            text.append(NSAttributedString(string: summary.goal + "\n", attributes: goal))
            if !summary.point.isEmpty { text.append(NSAttributedString(string: summary.point + "\n", attributes: body)) }
            let (state, rest) = summary.state
            let quiet = ink.withAlphaComponent(0.6)
            if let look = look(of: state) {
                let word = body.merging([.foregroundColor: quiet, .font: NSFont.systemFont(ofSize: size, weight: .semibold)]) { $1 }
                text.append(symbol(look.symbol, size: size, color: quiet, attributes: word))
                text.append(NSAttributedString(string: " " + look.name + "  ", attributes: word))
                text.append(NSAttributedString(string: rest + "\n", attributes: body))
            } else if !summary.next.isEmpty {
                // An older summary's "next step", as it was.
                text.append(NSAttributedString(string: summary.next + "\n", attributes: body.merging([.foregroundColor: quiet]) { $1 }))
            }
        }
        text.append(symbol("sparkles", size: size - 3, color: ink.withAlphaComponent(0.5), attributes: small))
        text.append(NSAttributedString(string: " " + footer(ai).replacingOccurrences(of: "✨ ", with: ""), attributes: small))
        return text
    }

    private static func symbol(_ name: String, size: CGFloat, color: NSColor,
                               attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return NSAttributedString()
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: size)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        let symbol = NSMutableAttributedString(attachment: attachment)
        symbol.addAttributes(attributes, range: NSRange(location: 0, length: symbol.length))
        return symbol
    }
}
