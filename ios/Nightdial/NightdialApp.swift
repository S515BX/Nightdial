import SwiftUI

@main
struct NightdialApp: App {
    @StateObject private var model: AppModel

    init() {
        Store.moveLegacyData()   // playlists and settings saved by earlier versions
        Fonts.registerAll()   // bundled fonts must be ready before the first screen draws
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
                .environmentObject(model.vod)
        }
    }
}
