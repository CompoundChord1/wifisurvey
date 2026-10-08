import SwiftUI

@main
struct WiFiSurveyApp: App {
    @State private var store = SurveyStore()
    @State private var runner = MeasurementRunner()
    @State private var walker = WalkRecorder()
    @State private var location = LocationHelper()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SurveyListView()
            }
            .environment(store)
            .environment(runner)
            .environment(walker)
            .environment(location)
            .onOpenURL { url in
                ShortcutBridge.shared.handle(url: url)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { ShortcutBridge.shared.appBecameActive() }
            }
            #if DEBUG
            .task { await SelfTest.runIfRequested(store: store, runner: runner, location: location) }
            #endif
        }
    }
}
