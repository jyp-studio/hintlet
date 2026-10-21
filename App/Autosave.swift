import Foundation
import HintletCore

/// Saves the notes shortly after they change, at most once per `delay` however fast the user types.
@MainActor
final class Autosave {
    private static let delay: TimeInterval = 1

    private let store: NoteStore
    private let engine: NoteEngine
    private var timer: Timer?
    private var lastSaved: NotesDocument?
    /// Off when the notes file couldn't be read nor moved aside: saving would overwrite it.
    private let isEnabled: Bool

    init(store: NoteStore, engine: NoteEngine, isEnabled: Bool) {
        self.store = store
        self.engine = engine
        self.isEnabled = isEnabled
        lastSaved = engine.document
    }

    /// Every time saving is asked for, i.e. whenever the notes or what the user looks at may have changed
    /// (the central list follows along).
    var onSchedule: (() -> Void)?

    func schedule() {
        onSchedule?()
        guard isEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        // Common modes, so saving isn't held up while a menu is open or a note is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func saveNow() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let document = engine.document
        // Focus changes ask to save all the time; only write what actually changed.
        guard document != lastSaved else { return }
        do {
            try store.save(document)
            lastSaved = document
        } catch {
            // The next change tries again.
            NSLog("Hintlet：無法儲存便利貼（\(error)）")
        }
    }
}
