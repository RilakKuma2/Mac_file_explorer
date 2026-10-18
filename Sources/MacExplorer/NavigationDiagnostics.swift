import OSLog

enum NavigationDiagnostics {
    // Timings and random request IDs only; do not record paths or filenames.
    static let logger = Logger(subsystem: "app.macexplorer.filemanager", category: "Navigation")
}
