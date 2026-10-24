import SwiftUI

@main
struct TunerApp: App {
    @StateObject private var model: AppModel

    init() {
        Fonts.registerAll()   // bundled fonts must be ready before the first screen draws
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
        }
    }
}
