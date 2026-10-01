import SwiftUI
import SleepiUI

@main struct SleepiPreview: App {
    @State private var model = AppModel(demo: true)
    var body: some Scene {
        WindowGroup("sleepi · Preview") {
            SleepiRootView(model: model)
                .frame(minWidth: 390, idealWidth: 430, maxWidth: 700, minHeight: 740, idealHeight: 900)
        }
        .defaultSize(width: 430, height: 900)
        .windowResizability(.contentSize)
    }
}
