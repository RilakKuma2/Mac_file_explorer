import OSLog

enum FileDragDiagnostics {
    // Record lifecycle and counts only; never filenames, paths or pasteboard data.
    static let logger = Logger(subsystem: "app.macexplorer.filemanager", category: "FileDrag")
}
