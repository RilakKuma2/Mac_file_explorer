import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum AutomaticThumbnailPolicy {
    static let maximumFileSize: Int64 = 10 * 1_024 * 1_024
    static let maximumConcurrentRequests = 2

    private static let cloudMaterializationResourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey
    ]

    static func allows(_ item: FileItem) -> Bool {
        // Query this immediately before constructing a QLThumbnail request.
        // A File Provider item can become evicted after the directory listing
        // was built, and asking Quick Look for that placeholder can implicitly
        // download it. Reading these metadata keys does not materialize data.
        let cloudValues = try? item.url.resourceValues(
            forKeys: cloudMaterializationResourceKeys
        )
        return allows(
            isDirectory: item.isDirectory,
            isPackage: item.isPackage,
            isOnLocalVolume: item.isOnLocalVolume,
            byteCount: item.byteCount,
            isUbiquitousItem: cloudValues?.isUbiquitousItem,
            ubiquitousItemDownloadingStatus: cloudValues?.ubiquitousItemDownloadingStatus,
            ubiquitousItemIsDownloading: cloudValues?.ubiquitousItemIsDownloading
        )
    }

    static func allows(
        isDirectory: Bool,
        isPackage: Bool,
        isOnLocalVolume: Bool,
        byteCount: Int64?,
        isUbiquitousItem: Bool? = nil,
        ubiquitousItemDownloadingStatus: URLUbiquitousItemDownloadingStatus? = nil,
        ubiquitousItemIsDownloading: Bool? = nil,
        maximumFileSize: Int64 = maximumFileSize
    ) -> Bool {
        guard !isDirectory, !isPackage, isOnLocalVolume,
              let byteCount, byteCount >= 0 else { return false }
        guard byteCount <= maximumFileSize else { return false }
        return hasMaterializedContents(
            isUbiquitousItem: isUbiquitousItem,
            downloadingStatus: ubiquitousItemDownloadingStatus,
            isDownloading: ubiquitousItemIsDownloading
        )
    }

    private static func hasMaterializedContents(
        isUbiquitousItem: Bool?,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        isDownloading: Bool?
    ) -> Bool {
        // Some File Provider implementations report the downloading status
        // even when isUbiquitousItem is unavailable, so honor the strongest
        // signals independently. A download in progress is not safe either:
        // Quick Look could keep that download alive after its original caller
        // no longer needs the file.
        if downloadingStatus == .notDownloaded || isDownloading == true {
            return false
        }

        guard isUbiquitousItem == true else { return true }

        // Be conservative for a recognized cloud item with missing/unknown
        // status. Losing an automatic thumbnail is preferable to silently
        // materializing user data. Explicit Quick Look uses QLPreviewPanel and
        // does not pass through this policy.
        return downloadingStatus == .downloaded || downloadingStatus == .current
    }
}

final class ThumbnailRequestToken {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    fileprivate init(cancellation: (() -> Void)? = nil) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }
}

private final class ThumbnailWork {
    enum State {
        case checkingEligibility
        case queued
        case active
        case finished
    }

    let id = UUID()
    let key: NSString
    let request: QLThumbnailGenerator.Request
    var callbacks: [UUID: (NSImage?) -> Void]
    var state: State = .checkingEligibility

    init(
        key: NSString,
        request: QLThumbnailGenerator.Request,
        callbackID: UUID,
        callback: @escaping (NSImage?) -> Void
    ) {
        self.key = key
        self.request = request
        self.callbacks = [callbackID: callback]
    }
}

final class FileIconProvider {
    static let shared = FileIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let requestLock = NSLock()
    private let eligibilityQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.macexplorer.thumbnail-eligibility"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = AutomaticThumbnailPolicy.maximumConcurrentRequests
        return queue
    }()
    private var workByKey: [NSString: ThumbnailWork] = [:]
    private var queuedWork: [ThumbnailWork] = []
    private var activeWork: [UUID: ThumbnailWork] = [:]

    private init() {
        cache.countLimit = 512
        thumbnailCache.countLimit = 768
    }

    func icon(for item: FileItem) -> NSImage {
        let key = item.url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let icon: NSImage
        if Self.usesApplicationIcon(for: item) {
            icon = NSWorkspace.shared.icon(forFile: item.url.path)
        } else if item.isDirectory && !item.isPackage {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if let contentType = item.contentType {
            icon = NSWorkspace.shared.icon(for: contentType)
        } else if let type = UTType(filenameExtension: item.url.pathExtension) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(for: .data)
        }
        cache.setObject(icon, forKey: key)
        return icon
    }

    static func usesApplicationIcon(for item: FileItem) -> Bool {
        item.isOnLocalVolume && (item.contentType?.conforms(to: .applicationBundle) == true
            || (item.isDirectory && item.url.pathExtension.lowercased() == "app"))
    }

    func folderIcon() -> NSImage {
        let key = "__generic_folder__" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(for: .folder)
        cache.setObject(icon, forKey: key)
        return icon
    }

    @discardableResult
    func requestThumbnail(
        for item: FileItem,
        size: CGSize,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailRequestToken {
        // Cheap listing metadata can be checked immediately. File Provider and
        // ubiquity keys are intentionally resolved on eligibilityQueue below;
        // querying them synchronously for every visible cell stalls browsing.
        guard AutomaticThumbnailPolicy.allows(
            isDirectory: item.isDirectory,
            isPackage: item.isPackage,
            isOnLocalVolume: item.isOnLocalVolume,
            byteCount: item.byteCount
        ) else {
            completion(nil)
            return ThumbnailRequestToken()
        }

        let modified = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(item.url.standardizedFileURL.path)|\(Int(size.width))x\(Int(size.height))|\(modified)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            completion(cached)
            return ThumbnailRequestToken()
        }

        let callbackID = UUID()
        let token = ThumbnailRequestToken { [weak self] in
            self?.cancelRequest(key: key, callbackID: callbackID)
        }

        requestLock.lock()
        if let existingWork = workByKey[key] {
            existingWork.callbacks[callbackID] = completion
            requestLock.unlock()
            return token
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .icon]
        )
        let work = ThumbnailWork(
            key: key,
            request: request,
            callbackID: callbackID,
            callback: completion
        )
        workByKey[key] = work
        requestLock.unlock()

        eligibilityQueue.addOperation { [weak self, weak work] in
            guard let self, let work else { return }
            self.finishEligibilityCheck(for: work, allowed: AutomaticThumbnailPolicy.allows(item))
        }
        return token
    }

    private func finishEligibilityCheck(for work: ThumbnailWork, allowed: Bool) {
        var rejectedCallbacks: [(NSImage?) -> Void] = []
        requestLock.lock()
        guard workByKey[work.key] === work,
              work.state == .checkingEligibility,
              !work.callbacks.isEmpty else {
            requestLock.unlock()
            return
        }
        if allowed {
            work.state = .queued
            queuedWork.append(work)
        } else {
            workByKey.removeValue(forKey: work.key)
            rejectedCallbacks = Array(work.callbacks.values)
            work.callbacks.removeAll()
            work.state = .finished
        }
        requestLock.unlock()

        if !rejectedCallbacks.isEmpty {
            DispatchQueue.main.async {
                rejectedCallbacks.forEach { $0(nil) }
            }
        }
        if allowed { startQueuedWorkIfPossible() }
    }

    private func cancelRequest(key: NSString, callbackID: UUID) {
        var requestToCancel: QLThumbnailGenerator.Request?

        requestLock.lock()
        if let work = workByKey[key] {
            work.callbacks.removeValue(forKey: callbackID)
            if work.callbacks.isEmpty {
                workByKey.removeValue(forKey: key)
                switch work.state {
                case .checkingEligibility:
                    work.state = .finished
                case .queued:
                    work.state = .finished
                    queuedWork.removeAll { $0 === work }
                case .active:
                    requestToCancel = work.request
                case .finished:
                    break
                }
            }
        }
        requestLock.unlock()

        if let requestToCancel {
            QLThumbnailGenerator.shared.cancel(requestToCancel)
        }
        startQueuedWorkIfPossible()
    }

    private func startQueuedWorkIfPossible() {
        var workToStart: [ThumbnailWork] = []

        requestLock.lock()
        while activeWork.count < AutomaticThumbnailPolicy.maximumConcurrentRequests,
              !queuedWork.isEmpty {
            let work = queuedWork.removeFirst()
            guard work.state == .queued, !work.callbacks.isEmpty else { continue }
            work.state = .active
            activeWork[work.id] = work
            workToStart.append(work)
        }
        requestLock.unlock()

        for work in workToStart {
            QLThumbnailGenerator.shared.generateBestRepresentation(for: work.request) { [weak self, weak work] representation, _ in
                guard let self, let work else { return }
                self.finish(work: work, image: representation?.nsImage)
            }

            // Cancellation can race with the small gap between dequeuing and
            // submitting the Quick Look request. Repeat it after submission so
            // a cell that already went offscreen never leaves live QL work.
            requestLock.lock()
            let shouldCancel = work.callbacks.isEmpty && work.state == .active
            requestLock.unlock()
            if shouldCancel {
                QLThumbnailGenerator.shared.cancel(work.request)
            }
        }
    }

    private func finish(work: ThumbnailWork, image: NSImage?) {
        requestLock.lock()
        guard activeWork.removeValue(forKey: work.id) != nil else {
            requestLock.unlock()
            return
        }
        if workByKey[work.key] === work {
            workByKey.removeValue(forKey: work.key)
        }
        let callbacks = Array(work.callbacks.values)
        work.callbacks.removeAll()
        work.state = .finished
        requestLock.unlock()

        if let image, !callbacks.isEmpty {
            thumbnailCache.setObject(image, forKey: work.key)
        }
        DispatchQueue.main.async {
            callbacks.forEach { $0(image) }
        }
        startQueuedWorkIfPossible()
    }
}
