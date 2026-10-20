import AppKit

/// Hintlet is never the active app (its notes are non-activating panels), and macOS only lets the active app
/// set the pointer. This asks the window server to let it set the pointer from the background too, so a
/// note's edges show the resize pointer without first clicking into the note. It is a private window-server
/// property, looked up at run time; if it is missing the pointer only changes while a note is being typed in.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func enable() {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetConnectionProperty.self)(id, id, "SetsCursorInBackground" as CFString,
                                                                        kCFBooleanTrue)
    }
}
