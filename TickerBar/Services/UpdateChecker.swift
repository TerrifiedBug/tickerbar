import Foundation
import Sparkle

@MainActor
final class UpdateChecker: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    init() {
        // Always run Sparkle, including for Homebrew installs. The cask sets
        // `auto_updates true` so brew defers to Sparkle instead of fighting
        // it. (This used to disable Sparkle whenever a /Caskroom/tickerbar
        // dir existed, which left brew users no way to update in-app.)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { updaterController.updater }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
}
