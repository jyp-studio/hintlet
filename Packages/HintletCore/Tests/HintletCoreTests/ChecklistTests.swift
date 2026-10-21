import Foundation
import Testing
import HintletCore

/// Applies an edit the way the text view does, for checking the result.
private func applying(_ edit: TextEdit?, to text: String) -> (text: String, caret: Int)? {
    guard let edit else { return nil }
    return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.caret)
}

@Suite("勾選清單")
struct ChecklistEditing {
    @Test("點清單項目的圓圈，打勾與取消來回切換")
    func togglesAnItem() {
        let text = "採買\n☐ 牛奶\n☑ 蛋"
        let milk = (text as NSString).range(of: "☐").location
        let eggs = (text as NSString).range(of: "☑").location

        #expect(applying(Checklist.toggle(in: text, at: milk), to: text)?.text == "採買\n☑ 牛奶\n☑ 蛋")
        #expect(applying(Checklist.toggle(in: text, at: eggs), to: text)?.text == "採買\n☐ 牛奶\n☐ 蛋")
    }

    @Test("點的不是圓圈就不切換")
    func onlyTheBoxToggles() {
        let text = "採買\n☐ 牛奶"
        #expect(Checklist.toggle(in: text, at: 0) == nil)
        #expect(Checklist.toggle(in: text, at: (text as NSString).range(of: "牛").location) == nil)
    }

    @Test("在清單項目結尾按 Enter，下一行接著是新的項目")
    func enterContinuesTheList() {
        let text = "☑ 牛奶"
        let result = applying(Checklist.lineBreak(in: text, at: text.utf16.count), to: text)
        #expect(result?.text == "☑ 牛奶\n☐ ")
        #expect(result?.caret == "☑ 牛奶\n☐ ".utf16.count)
    }

    @Test("在空的項目按 Enter，結束清單（拿掉圓圈）")
    func enterOnAnEmptyItemEndsTheList() {
        let text = "☐ 牛奶\n☐ "
        let result = applying(Checklist.lineBreak(in: text, at: text.utf16.count), to: text)
        #expect(result?.text == "☐ 牛奶\n")
        #expect(result?.caret == "☐ 牛奶\n".utf16.count)
    }

    @Test("一般行按 Enter 照常換行")
    func enterOnPlainTextIsNormal() {
        #expect(Checklist.lineBreak(in: "下一步", at: 3) == nil)
    }

    @Test("在行首打「[] 」或「[ ] 」自動變成清單項目")
    func bracketsBecomeABox() {
        for typed in ["[] ", "[ ] "] {
            let text = "採買\n" + typed
            let result = applying(Checklist.autoformat(in: text, caret: text.utf16.count), to: text)
            #expect(result?.text == "採買\n☐ ")
            #expect(result?.caret == "採買\n☐ ".utf16.count)
        }
        #expect(Checklist.autoformat(in: "說明 [] ", caret: 6) == nil)
    }

    @Test("⇧⌘L 把選到的行變成清單項目；全部已是項目時拿掉圓圈")
    func togglesLinesIntoAList() {
        let text = "牛奶\n☐ 蛋\n麵包"
        let all = NSRange(location: 0, length: text.utf16.count)
        #expect(applying(Checklist.toggleLines(in: text, selection: all), to: text)?.text == "☐ 牛奶\n☐ 蛋\n☐ 麵包")

        let list = "☐ 牛奶\n☑ 蛋"
        #expect(applying(Checklist.toggleLines(in: list, selection: NSRange(location: 0, length: list.utf16.count)),
                         to: list)?.text == "牛奶\n蛋")
    }

    @Test("⇧⌘L 保留空白行與 Windows 換行，空白行不加圓圈")
    func keepsBlankLinesAndLineEndings() {
        let text = "a\n\nb"
        let all = NSRange(location: 0, length: text.utf16.count)
        #expect(applying(Checklist.toggleLines(in: text, selection: all), to: text)?.text == "☐ a\n\n☐ b")

        let list = "☐ a\n\n☐ b"
        #expect(applying(Checklist.toggleLines(in: list, selection: NSRange(location: 0, length: list.utf16.count)),
                         to: list)?.text == "a\n\nb")

        let crlf = "a\r\nb"
        #expect(applying(Checklist.toggleLines(in: crlf, selection: NSRange(location: 0, length: crlf.utf16.count)),
                         to: crlf)?.text == "☐ a\r\n☐ b")
    }

    @Test("游標在圓圈前面時按 Enter，照常換行，不弄壞項目")
    func enterBeforeTheBoxIsNormal() {
        #expect(Checklist.lineBreak(in: "☐ 牛奶", at: 0) == nil)
        #expect(Checklist.lineBreak(in: "☐ 牛奶", at: 1) == nil)
    }

    @Test("在項目開頭按 delete，拿掉整個圓圈，變回一般文字")
    func deleteAtTheStartRemovesTheBox() {
        for text in ["☐ ", "☐ 牛奶"] {
            let result = applying(Checklist.deleteBackward(in: text, at: 2), to: text)
            #expect(result?.text == String(text.dropFirst(2)))
            #expect(result?.caret == 0)
        }
        let list = "採買\n☑ 蛋"
        #expect(applying(Checklist.deleteBackward(in: list, at: 5), to: list)?.text == "採買\n蛋")
    }

    @Test("其他位置的 delete 照常")
    func deleteElsewhereIsNormal() {
        #expect(Checklist.deleteBackward(in: "☐ 牛奶", at: 4) == nil)
        #expect(Checklist.deleteBackward(in: "牛奶", at: 1) == nil)
    }

    @Test("⇧⌘L 只作用在游標所在的行")
    func togglesTheCaretLine() {
        let text = "標題\n牛奶"
        let caret = NSRange(location: text.utf16.count, length: 0)
        #expect(applying(Checklist.toggleLines(in: text, selection: caret), to: text)?.text == "標題\n☐ 牛奶")
    }

    @Test("找出每個圓圈的位置與是否打勾，供畫面繪製")
    func findsTheBoxes() {
        let text = "採買\n☐ 牛奶\n☑ 蛋"
        #expect(Checklist.boxes(in: text) == [
            .init(location: 3, isChecked: false, lineRange: NSRange(location: 3, length: 4)),
            .init(location: 8, isChecked: true, lineRange: NSRange(location: 8, length: 3)),
        ])
    }
}
