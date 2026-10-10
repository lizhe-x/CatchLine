import SwiftUI

@main
struct CatchlineApp: App {
    @State private var auth: AuthService
    @State private var captioner: Captioner

    init() {
        let auth = AuthService()
        _auth = State(initialValue: auth)
        _captioner = State(initialValue: Captioner(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    CaptionScreen()
                } else {
                    SignInScreen()
                }
            }
            .environment(auth)
            .environment(captioner)
        }
    }
}
