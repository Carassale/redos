import Foundation
import Observation
import Sparkle

/// Sparkle updates from the appcast in the GitHub repo; the beta channel is opt-in.
@MainActor
@Observable
final class Updater {
    nonisolated static let betaKey = "updates.beta"

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let delegate = ChannelDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] in
            let updater = $0
            _ = $1
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var receivesBetas: Bool {
        get { UserDefaults.standard.bool(forKey: Self.betaKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.betaKey)
            // A cached appcast would hide the other channel until the next scheduled check.
            controller.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Updater.betaKey) ? ["beta"] : []
    }
}
