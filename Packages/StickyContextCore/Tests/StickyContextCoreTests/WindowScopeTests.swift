import CoreGraphics
import Testing
import StickyContextCore

/// AppKit global coordinates: origin at the bottom-left of the primary screen, y grows upward.
private let laptop = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 79, width: 1512, height: 870))
private let external = Screen(frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
                              visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1440))

private let downloadsFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
private let downloads = ObservedWindow(id: WindowID(1), appName: "Finder", title: "Downloads", frame: downloadsFrame)
private let documents = ObservedWindow(id: WindowID(2), appName: "Finder", title: "Documents",
                                       frame: CGRect(x: 300, y: 150, width: 700, height: 500))

private func engineFocused(on window: ObservedWindow) -> NoteEngine {
    let engine = NoteEngine(screens: [laptop, external])
    engine.observe(.window(window))
    return engine
}

private func moved(_ window: ObservedWindow, to frame: CGRect) -> ObservedWindow {
    var copy = window
    copy.frame = frame
    return copy
}

@Suite("綁定視窗")
struct BindingToWindows {
    @Test("在焦點視窗按 ⌘⌥N，便利貼綁在該視窗，標籤寫出 App 與視窗標題")
    func bindsToFocusedWindow() {
        let engine = engineFocused(on: downloads)

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Finder", title: "Downloads")])
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 300, y: 520, width: 240, height: 180)])
    }

    @Test("沒有可辨識的視窗時，便利貼是浮動的")
    func floatsWithoutAWindow() {
        let engine = NoteEngine(screens: [laptop])
        engine.observe(.unidentified)

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.floating])
    }

    @Test("游標不在視窗內時，便利貼放在視窗右上角，多張依序錯開")
    func placesNotesAtTopRightWhenCursorIsOutside() {
        let engine = engineFocused(on: downloads)

        engine.createNote(at: CGPoint(x: 1300, y: 900))
        engine.createNote(at: CGPoint(x: 1300, y: 900))

        // 16pt from the right edge, 40pt below the top so the title bar stays clear; then 24pt down-left.
        #expect(engine.displayedNotes.map(\.frame) == [
            CGRect(x: 644, y: 580, width: 240, height: 180),
            CGRect(x: 620, y: 556, width: 240, height: 180),
        ])
    }

    @Test("視窗比便利貼還小時，便利貼對齊視窗左上角")
    func smallWindowAlignsNoteTopLeft() {
        let tiny = ObservedWindow(id: WindowID(4), appName: "Calculator", title: "", frame: CGRect(x: 100, y: 400, width: 200, height: 150))
        let engine = engineFocused(on: tiny)

        engine.createNote(at: CGPoint(x: 1300, y: 900))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 100, y: 370, width: 240, height: 180)])
    }

    @Test("預設位置附近已有便利貼（例如稍微拖過）時，新的仍會錯開")
    func staggersPastNearbyNotes() {
        let engine = engineFocused(on: downloads)
        let first = engine.createNote(at: CGPoint(x: 1300, y: 900))
        engine.moveNote(first, to: CGPoint(x: 646, y: 579))

        engine.createNote(at: CGPoint(x: 1300, y: 900))

        #expect(engine.displayedNotes.map(\.frame).last == CGRect(x: 620, y: 556, width: 240, height: 180))
    }

    @Test("同一個視窗可以有多張便利貼")
    func manyNotesOnOneWindow() {
        let engine = engineFocused(on: downloads)

        engine.createNote(at: CGPoint(x: 200, y: 700))
        engine.createNote(at: CGPoint(x: 500, y: 700))

        #expect(engine.displayedNotes.count == 2)
    }

    @Test("同標題的兩個視窗各自獨立，不以標題匹配")
    func windowsWithTheSameTitleAreDistinct() {
        let twin = ObservedWindow(id: WindowID(3), appName: "Finder", title: "Downloads", frame: downloadsFrame)
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(twin))

        #expect(engine.displayedNotes.isEmpty)
    }
}

@Suite("切換時隱藏與顯示")
struct ShowingAndHiding {
    @Test("切到別的視窗時隱藏，切回來在原位置出現")
    func hidesAwayAndReturns() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let original = engine.displayedNotes

        engine.observe(.window(documents))
        #expect(engine.displayedNotes.isEmpty)

        engine.observe(.window(downloads))
        #expect(engine.displayedNotes == original)
    }

    @Test("焦點正在變動、還無法確定時，先隱藏綁定的便利貼")
    func hidesWhileUnresolved() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.unidentified)

        #expect(engine.displayedNotes.isEmpty)
    }

    @Test("浮動便利貼在任何視窗都顯示")
    func floatingNotesStayVisible() {
        let engine = NoteEngine(screens: [laptop])
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(downloads))
        engine.observe(.window(documents))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.floating])
    }

    @Test("前景變成 Hintlet 自己時沿用前一個工作內容，便利貼不被隱藏")
    func ownAppKeepsPreviousContext() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        let shown = engine.displayedNotes

        engine.observe(.ownApp)

        #expect(engine.displayedNotes == shown)
    }

    @Test("前景是 Hintlet 自己時新增的便利貼，仍綁在前一個視窗")
    func creatingWhileOwnAppIsFrontmostUsesPreviousWindow() {
        let engine = engineFocused(on: downloads)
        engine.observe(.ownApp)

        engine.createNote(at: CGPoint(x: 300, y: 700))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Finder", title: "Downloads")])
    }

    @Test("視窗最小化時隱藏，還原時重新出現")
    func hidesWhileMinimized() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        var minimized = downloads
        minimized.isMinimized = true

        engine.observe(.window(minimized))
        #expect(engine.displayedNotes.isEmpty)

        engine.observe(.window(downloads))
        #expect(engine.displayedNotes.count == 1)
    }

    @Test("視窗改名後標籤跟著更新")
    func labelFollowsTitle() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))
        var renamed = downloads
        renamed.title = "Desktop"

        engine.observe(.window(renamed))

        #expect(engine.displayedNotes.map(\.scopeLabel) == [.window(appName: "Finder", title: "Desktop")])
    }
}

@Suite("跟著視窗走")
struct FollowingTheWindow {
    @Test("視窗移動時便利貼跟著移動")
    func followsMove() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(moved(downloads, to: downloadsFrame.offsetBy(dx: 100, dy: -50))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 400, y: 470, width: 240, height: 180)])
    }

    @Test("視窗移到另一個螢幕時便利貼跟過去")
    func followsToAnotherScreen() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(moved(downloads, to: CGRect(x: 2000, y: -300, width: 800, height: 600))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 2200, y: 20, width: 240, height: 180)])
    }

    @Test("視窗放大時，靠右上角的便利貼維持與右上角的距離")
    func keepsDistanceFromNearestCornerOnResize() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 1300, y: 900)) // top-right default spot

        engine.observe(.window(moved(downloads, to: CGRect(x: 100, y: 100, width: 1000, height: 700))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 844, y: 580, width: 240, height: 180)])
    }

    @Test("視窗縮小時，便利貼維持與最近角落的距離，可以超出視窗")
    func keepsCornerDistanceWhenWindowShrinks() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700)) // nearest the top-left corner

        engine.observe(.window(moved(downloads, to: CGRect(x: 100, y: 500, width: 300, height: 300))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 300, y: 520, width: 240, height: 180)])
    }

    @Test("拖到視窗外的便利貼停在放開的位置，並隨視窗移動維持相對位置")
    func noteOutsideWindowKeepsItsPlace() {
        let engine = engineFocused(on: downloads)
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.moveNote(id, to: CGPoint(x: 950, y: 400)) // hanging off the right edge
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 950, y: 400, width: 240, height: 180)])

        engine.observe(.window(moved(downloads, to: downloadsFrame.offsetBy(dx: 100, dy: -50))))
        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 1050, y: 350, width: 240, height: 180)])
    }

    @Test("視窗外的便利貼切走再切回來，位置不變")
    func noteOutsideWindowSurvivesSwitching() {
        let engine = engineFocused(on: downloads)
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.moveNote(id, to: CGPoint(x: 950, y: 400))

        engine.observe(.window(documents))
        engine.observe(.window(downloads))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 950, y: 400, width: 240, height: 180)])
    }

    @Test("視窗移到螢幕邊緣時，視窗外的便利貼停在螢幕內")
    func noteOutsideWindowStaysOnScreen() {
        let engine = engineFocused(on: downloads)
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))
        engine.moveNote(id, to: CGPoint(x: 0, y: 400)) // 100pt left of the window

        engine.observe(.window(moved(downloads, to: CGRect(x: 0, y: 200, width: 800, height: 600))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 0, y: 400, width: 240, height: 180)])
    }

    @Test("視窗進入全螢幕時便利貼仍在視窗內")
    func followsIntoFullScreen() {
        let engine = engineFocused(on: downloads)
        engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.observe(.window(moved(downloads, to: laptop.frame)))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 200, y: 702, width: 240, height: 180)])
    }

    @Test("拖曳綁定的便利貼後，之後依新位置跟著視窗")
    func draggedNoteFollowsFromNewSpot() {
        let engine = engineFocused(on: downloads)
        let id = engine.createNote(at: CGPoint(x: 300, y: 700))

        engine.moveNote(id, to: CGPoint(x: 500, y: 300))
        engine.observe(.window(moved(downloads, to: downloadsFrame.offsetBy(dx: 50, dy: 0))))

        #expect(engine.displayedNotes.map(\.frame) == [CGRect(x: 550, y: 300, width: 240, height: 180)])
    }
}
