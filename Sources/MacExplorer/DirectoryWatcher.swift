import Foundation
import Darwin

enum DirectoryWatcherChange: Equatable {
    case contents
    case invalidated
}

final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var watchedPath: String?
    private var changeHandler: ((DirectoryWatcherChange) -> Void)?
    private var pendingChange: DispatchWorkItem?

    func watch(_ url: URL, onChange: @escaping (DirectoryWatcherChange) -> Void) {
        let path = url.standardizedFileURL.path
        if source != nil, watchedPath == path {
            changeHandler = onChange
            return
        }
        stop()

        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedPath = path
        changeHandler = onChange

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            if !flags.intersection([.delete, .rename]).isEmpty {
                let handler = self.changeHandler
                self.stop()
                handler?(.invalidated)
            } else {
                self.scheduleChangeNotification()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
        descriptor = -1
        watchedPath = nil
        changeHandler = nil
    }

    private func scheduleChangeNotification() {
        pendingChange?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.changeHandler?(.contents)
        }
        pendingChange = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    deinit {
        stop()
    }
}
