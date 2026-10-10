import SwiftUI

struct SignInScreen: View {
    @Environment(AuthService.self) private var auth
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Catchline").font(.largeTitle.bold())
                Text("Catch every word.").foregroundStyle(.secondary)
            }
            Spacer()
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                Task { await signIn() }
            } label: {
                Text(busy ? "登录中…" : "登录")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        .padding(24)
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await auth.signIn()
            error = nil
        } catch AuthError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
