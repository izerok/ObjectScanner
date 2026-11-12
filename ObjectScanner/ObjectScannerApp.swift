import SwiftUI

@main
struct ObjectScannerApp: App {
    init() {
        // Default UI language for this fork: Simplified Chinese. Set only when
        // the user has not chosen an app language, so a per-app language picked
        // in Settings still wins.
        if UserDefaults.standard.object(forKey: "AppleLanguages") == nil {
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    /// One store for the whole app: it owns the on-disk scan library and hands out
    /// per-scan workspaces to whichever engine is running.
    @State private var storage = ScanStorage()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(storage)
                .preferredColorScheme(.dark)
        }
    }
}
