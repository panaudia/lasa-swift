// The example app: one screen that joins a space with the Swift
// client. The app owns the audio session and its lifecycle object and
// hands both to the library (lasa-swift.md §2.2, §2.5). 2026-11-03.

import SwiftUI

@main
struct LasaExampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
