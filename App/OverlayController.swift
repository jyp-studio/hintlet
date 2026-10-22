import AppKit
import HintletCore

/// Keeps one note panel on screen for each note the engine wants displayed.
@MainActor
final class OverlayController {
    private let engine: NoteEngine
    private let onFinishEditing: () -> Void
    /// Something worth saving changed (text, position, a note found again).
    private let onNotesChanged: () -> Void
    /// An AI note asked for a summary (it was just made, or "更新" was pressed).
    var onSummariesRequested: (() -> Void)?
    /// The note actions for a note's right-click menu.
    var noteMenuItems: (() -> [NSMenuItem])?
    private var panels: [NoteID: NotePanel] = [:]
    /// "可能是這裡？" tags, one per waiting note suggested for the focused window.
    private var markers: [NoteID: RecoveryMarkerPanel] = [:]
    private var pendingMarkerReveals: Set<NoteID> = []
    private static let markerGap: CGFloat = 6
    private static let settleDelay: TimeInterval = 0.08
    private var pendingReveals: Set<NoteID> = []
    private var windowInMotion = false
    /// Notes that were showing when their window started moving.
    private var steppedAside: Set<NoteID> = []
    /// Notes faded for the caret in the app in front.
    private var givingWay: Set<NoteID> = []
    /// Notes the caret has left, about to come back.
    private var returning: [NoteID: DispatchWorkItem] = [:]
    /// Long enough that pressing Return under a note doesn't make it bounce back and forth.
    private static let returnDelay: TimeInterval = 0.8

    init(engine: NoteEngine, onFinishEditing: @escaping () -> Void, onNotesChanged: @escaping () -> Void) {
        self.engine = engine
        self.onFinishEditing = onFinishEditing
        self.onNotesChanged = onNotesChanged
    }

    /// Redraws after the engine's notes or the observed context changed.
    /// Every note, shown or not, is set again at the settings' text size.
    func textSizeChanged() {
        panels.values.forEach { $0.textSizeChanged() }
    }

    func render() {
        apply()
    }

    /// While the focused window moves, resizes, minimizes or goes full screen, its notes step aside:
    /// an overlay can't move in lockstep with the window server, and trailing behind looks broken.
    func setWindowInMotion(_ moving: Bool) {
        windowInMotion = moving
        apply()
    }

    private func apply() {
        let displayed = engine.displayedNotes
        let displayedIDs = Set(displayed.map(\.id))

        // Notes that no longer match go at once, so they never linger over other content (spec).
        // Their panels stay around and are reused when the note shows again (also after a deleted note
        // is restored).
        for (id, panel) in panels where !displayedIDs.contains(id) {
            panel.conceal(animated: false)
            steppedAside.remove(id)
            if givingWay.remove(id) != nil {
                returning.removeValue(forKey: id)?.cancel()
                panel.giveWay(false)
            }
        }
        var appearing: [NoteID] = []
        for note in displayed {
            let panel = panels[note.id] ?? makePanel(for: note.id)
            panel.update(note)
            if isSteppingAside(note) {
                if panel.isShown { steppedAside.insert(note.id) }
                panel.conceal(animated: true)
            } else if steppedAside.remove(note.id) != nil {
                // Back from stepping aside on the same window, which is still focused: no need to wait.
                panel.reveal()
            } else if !panel.isShown {
                appearing.append(note.id)
            }
        }
        revealWhenSettled(appearing)
        applyMarkers()
    }

    /// Tags step aside with the window like notes do, and wait for focus to settle before appearing.
    private func applyMarkers() {
        let candidates = engine.recoveryCandidates
        let wanted = Set(candidates.map(\.noteID))
        let unmatched = Set(engine.unmatchedNotes.map(\.id))
        for (id, marker) in markers where !wanted.contains(id) {
            if marker.isShown { marker.conceal() }
            // Found again: its tag won't be needed any more.
            if !unmatched.contains(id) {
                marker.close()
                markers[id] = nil
            }
        }
        var placed: [CGRect] = []
        var appearing: [NoteID] = []
        for candidate in candidates {
            let marker = markers[candidate.noteID] ?? makeMarker(for: candidate.noteID)
            // At the top-left of where the note would go; tags for notes that would overlap stack downwards.
            let topLeft = CGPoint(x: candidate.noteFrame.minX, y: candidate.noteFrame.maxY)
            marker.show(candidate)
            var frame = marker.fittingFrame(topLeftAt: topLeft)
            while placed.contains(where: { $0.insetBy(dx: 0, dy: -Self.markerGap / 2).intersects(frame) }) {
                frame.origin.y -= frame.height + Self.markerGap
            }
            placed.append(frame)
            marker.place(at: frame)
            if windowInMotion {
                if marker.isShown { marker.conceal() }
            } else if !marker.isShown {
                appearing.append(candidate.noteID)
            }
        }
        let fresh = Set(appearing).subtracting(pendingMarkerReveals)
        guard !fresh.isEmpty else { return }
        pendingMarkerReveals.formUnion(fresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self else { return }
            pendingMarkerReveals.subtract(fresh)
            guard !windowInMotion else { return }
            for candidate in engine.recoveryCandidates where fresh.contains(candidate.noteID) {
                guard let marker = markers[candidate.noteID], !marker.isShown,
                      marker.windowID == candidate.windowID else { continue }
                marker.reveal()
            }
        }
    }

    private func makeMarker(for id: NoteID) -> RecoveryMarkerPanel {
        let marker = RecoveryMarkerPanel(
            onConfirm: { [weak self] in
                guard let self, let windowID = markers[id]?.windowID else { return }
                engine.confirmRecovery(of: id, on: windowID)
                render()
                onNotesChanged()
            },
            onDismiss: { [weak self] in
                guard let self, let windowID = markers[id]?.windowID else { return }
                engine.dismissRecovery(of: id, on: windowID)
                render()
            }
        )
        markers[id] = marker
        return marker
    }

    /// Every note of a moving window steps aside, the one being typed in too: the window is only moved,
    /// minimized or taken full screen by a click in it, which ends the typing anyway.
    private func isSteppingAside(_ note: DisplayedNote) -> Bool {
        windowInMotion && note.windowID != nil
    }

    /// Notes the user types under in the app in front fade where they are, and come back a moment after the caret
    /// has left. Only typing fades a note: focus landing in a field as the user switches apps, threads or
    /// desktops would fade it just before it hides for the switch. The note being typed in stays as it is.
    func caretMoved(to caret: CGRect?, typed: Bool) {
        for note in engine.displayedNotes {
            guard let panel = panels[note.id], panel.isShown, !panel.isEditing else { continue }
            if let caret, typed || givingWay.contains(note.id), GivingWay.fades(note.frame, forCaret: caret) {
                returning.removeValue(forKey: note.id)?.cancel()
                givingWay.insert(note.id)
                panel.giveWay(true)
            } else if givingWay.contains(note.id), returning[note.id] == nil {
                let comeBack = DispatchWorkItem { [weak self] in
                    self?.returning[note.id] = nil
                    self?.givingWay.remove(note.id)
                    self?.panels[note.id]?.giveWay(false)
                }
                returning[note.id] = comeBack
                // Also when another app came in front: by then the note has usually hidden for the switch, and
                // coming back at once would flash it first.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnDelay, execute: comeBack)
            }
        }
    }

    /// Holding ⌥ makes every note but the one being typed in see-through, with clicks going to what is under it.
    func peekThrough(_ peeking: Bool) {
        for panel in panels.values where !panel.isEditing || !peeking {
            panel.peekThrough(peeking)
        }
    }

    /// Notes left on another desktop for a window that has since closed must not slide back into view.
    func windowsGone(_ ids: [WindowID]) {
        let gone = Set(ids)
        for (_, panel) in panels where panel.windowID.map(gone.contains) == true {
            panel.conceal(animated: false)
            panel.orderOut(nil)
        }
    }

    /// Focus can bounce between windows while the user switches; better late than wrong, so notes that
    /// appear wait a moment and only show if they are still wanted.
    private func revealWhenSettled(_ ids: [NoteID]) {
        let fresh = Set(ids).subtracting(pendingReveals)
        guard !fresh.isEmpty else { return }
        pendingReveals.formUnion(fresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self else { return }
            pendingReveals.subtract(fresh)
            for note in engine.displayedNotes where fresh.contains(note.id) && !isSteppingAside(note) {
                guard let panel = panels[note.id], !panel.isShown else { continue }
                panel.reveal()
            }
        }
    }

    /// Brings a note back from the trash, where it was.
    /// The note whose panel has the keyboard, which the menu bar's 便利貼 menu acts on.
    var currentNote: DisplayedNote? {
        guard let id = panels.first(where: { $0.value.isKeyWindow })?.key else { return nil }
        return engine.displayedNotes.first { $0.id == id }
    }

    // MARK: The menu bar's actions on the current note

    func setColorOfCurrentNote(_ color: NoteColor) {
        guard let note = currentNote, note.ai == nil else { return }
        change { $0.setColor(of: note.id, to: color) }
    }

    func setScopeOfCurrentNote(_ scope: BindingScope) {
        guard let note = currentNote else { return }
        change { $0.changeScope(of: note.id, to: scope) }
    }

    func toggleCurrentNoteCollapsed() {
        guard let id = currentNote?.id else { return }
        panels[id]?.toggleCollapsed()
    }

    func makeCurrentNoteOrdinary() {
        guard let id = currentNote?.id else { return }
        makeOrdinary(id)
    }

    /// The AI note becomes an ordinary one, keeping what the AI wrote as text the user can edit.
    private func makeOrdinary(_ id: NoteID) {
        change { $0.makeOrdinaryNote(id, summaryText: AINoteText.shownText) }
    }

    func deleteCurrentNote() {
        guard let id = currentNote?.id else { return }
        panels[id]?.delete()
    }

    func makeCurrentNoteAI() {
        guard let id = currentNote?.id else { return }
        panels[id]?.makeAI()
    }

    func refreshCurrentAINote() {
        guard let note = currentNote, note.ai != nil else { return }
        engine.requestSummary(note.id)
        onSummariesRequested?()
    }

    /// Puts the caret in the note.
    func focus(_ id: NoteID) {
        panels[id]?.beginEditing()
    }

    /// Into the trash.
    private func delete(_ id: NoteID) {
        guard let note = engine.displayedNotes.first(where: { $0.id == id }) else { return }
        // Nothing written, nothing to keep: an empty note just goes. An AI note always goes to the trash.
        if note.ai == nil, note.text.allSatisfy(\.isWhitespace) {
            discardIfEmpty(id)
            return
        }
        // Straight to the trash, no questions: it can be found there again for 30 days.
        change { $0.deleteNote(id) }
    }

    /// Makes a change the user asked for, shows it and saves it.
    private func change(_ body: (NoteEngine) -> Void) {
        body(engine)
        render()
        onNotesChanged()
    }

    /// A note left empty when editing ends is removed, panel and all.
    private func discardIfEmpty(_ id: NoteID) {
        guard engine.discardIfEmpty(id), let panel = panels.removeValue(forKey: id) else { return }
        steppedAside.remove(id)
        panel.conceal(animated: false)
        panel.orderOut(nil)
        panel.close()
        onNotesChanged()
    }

    private func makePanel(for id: NoteID) -> NotePanel {
        let panel = NotePanel(
            onTextChange: { [weak self] text in
                guard let self else { return }
                let offers = { [engine] in engine.displayedNotes.first { $0.id == id }?.offersAI }
                let offered = offers()
                engine.editText(of: id, to: text)
                // The first letter typed takes the AI offer away; emptying the note brings it back.
                if offers() != offered { render() }
                onNotesChanged()
            },
            onMove: { [weak self] origin in
                self?.engine.moveNote(id, to: origin)
                // The engine may have kept it on screen; the panel shows where the note really is.
                self?.render()
                self?.onNotesChanged()
            },
            onFinishEditing: { [weak self] in self?.onFinishEditing() }
        )
        panel.onSetFrame = { [weak self] frame in self?.change { $0.setFrame(of: id, to: frame) } }
        panel.onSetColor = { [weak self] color in self?.change { $0.setColor(of: id, to: color) } }
        panel.onSetCollapsed = { [weak self] collapsed in self?.change { $0.setCollapsed(id, collapsed) } }
        panel.onDelete = { [weak self] in self?.delete(id) }
        panel.scopeOptions = { [weak self] in self?.engine.scopeOptions(for: id) ?? [] }
        panel.onSetScope = { [weak self] scope in self?.change { $0.changeScope(of: id, to: scope) } }
        panel.canRefreshAI = { [weak self] in !(self?.engine.aiConversationKinds.isEmpty ?? true) }
        panel.onMakeAI = { [weak self] in
            // On a conversation that had another AI note, that one turns back into an ordinary note.
            self?.change { $0.makeAINote(id, summaryText: AINoteText.shownText) }
            self?.onSummariesRequested?()
        }
        panel.onRefreshAI = { [weak self] in
            self?.engine.requestSummary(id)
            self?.onSummariesRequested?()
        }
        panel.onMakeOrdinary = { [weak self] in self?.makeOrdinary(id) }
        panel.noteMenuItems = { [weak self] in self?.noteMenuItems?() ?? [] }
        panel.onEndEditing = { [weak self] in
            // After the panel has finished handing the keyboard back.
            DispatchQueue.main.async { self?.discardIfEmpty(id) }
        }
        panels[id] = panel
        return panel
    }
}
