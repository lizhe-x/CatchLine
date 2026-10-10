import SwiftUI

@main
struct CatchlineApp: App {
    @State private var store: SubscriptionStore
    @State private var captioner: Captioner

    init() {
        let store = SubscriptionStore()
        let api = APIClient()
        api.entitlementProvider = { await store.activeJWS }
        _store = State(initialValue: store)
        _captioner = State(initialValue: Captioner(api: api))
    }

    var body: some Scene {
        WindowGroup {
            CaptionScreen()
                .environment(store)
                .environment(captioner)
                .task {
                    await store.load()
                    await captioner.refreshPlan()
                }
                .onChange(of: store.activeJWS) {
                    Task { await captioner.refreshPlan() }
                }
        }
    }
}
