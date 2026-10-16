import AppKit
import Sparkle

/// Sparkle owns version comparison, signed downloads, installation and relaunch.
/// The public GitHub release hosts both the appcast and its signed archive.
final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )
    private var waitingForOperations: Timer?
    private var hasActiveOperations: Bool {
        FileOperationManager.shared.hasActiveOperations || ArchiveOperationManager.shared.hasActiveOperations
    }

    func start() {
        // `swift run` and unit tests are not installable app bundles.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller.startUpdater()
    }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        controller.updater.automaticallyChecksForUpdates.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        }
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveOperations else { return false }
        // A restart must not interrupt a copy, move, archive or queued undo.
        waitingForOperations?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard !self.hasActiveOperations else { return }
            timer.invalidate()
            self.waitingForOperations = nil
            installHandler()
        }
        waitingForOperations = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    deinit { waitingForOperations?.invalidate() }
}
