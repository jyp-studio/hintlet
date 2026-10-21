import CoreGraphics
import Testing
import HintletCore

/// A 240×180 note in the middle of the screen.
private let note = CGRect(x: 600, y: 400, width: 240, height: 180)

private func caret(x: CGFloat, y: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: 2, height: 18)
}

@Suite("自動讓路")
struct GivingWayTests {
    @Test("游標不在便利貼附近：不淡出")
    func staysWhenClear() {
        #expect(!GivingWay.fades(note, forCaret: caret(x: 100, y: 100)))
    }

    @Test("游標在便利貼底下：淡出")
    func fadesOverTheCaret() {
        #expect(GivingWay.fades(note, forCaret: caret(x: 700, y: 480)))
    }

    @Test("游標貼著便利貼左邊打字，接下來的字會跑進去：先淡出")
    func makesRoomForTheNextWords() {
        #expect(GivingWay.fades(note, forCaret: caret(x: 560, y: 480)))
    }

    @Test("游標在便利貼右邊：不淡出")
    func leavesRoomOnTheLeftOnly() {
        #expect(!GivingWay.fades(note, forCaret: caret(x: 870, y: 480)))
    }

    @Test("一整行輸入框碰到便利貼：淡出")
    func fadesForAWholeLine() {
        #expect(GivingWay.fades(note, forCaret: CGRect(x: 108, y: 560, width: 826, height: 29)))
    }
}
