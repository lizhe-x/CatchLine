import StoreKit
import SwiftUI

struct SettingsSheet: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(Captioner.self) private var captioner
    @Binding var showPaywall: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.sourceLang) private var sourceLang = "en"
    @AppStorage(Prefs.targetLang) private var targetLang = Language.defaultTarget
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.background) private var background = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    Picker("Listen to", selection: $sourceLang) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                    Picker("Translate into", selection: $targetLang) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                }
                Section {
                    TextField("Mark Johnson, Acme Corp, W-2", text: $terms, axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Keywords")
                } footer: {
                    Text("Names, companies, jargon. Separate with commas or new lines.")
                }
                Section {
                    TextField("Call with my landlord about renewing the lease and repairs.", text: $background, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Background (optional)")
                } footer: {
                    Text("Keywords and background are sent to the speech engine and noticeably improve accuracy for names and terms. They can’t be changed once a session starts.")
                }
                Section("Subscription") {
                    LabeledContent("Current plan", value: planName)
                    if let plan = captioner.plan {
                        LabeledContent(plan.kind == .free ? "Left today" as LocalizedStringKey : "Time left", value: remainingText(plan.remainingSeconds))
                    }
                    if store.isSubscribed {
                        Button("Manage Subscription") {
                            Task {
                                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                                try? await AppStore.showManageSubscriptions(in: scene)
                            }
                        }
                    } else {
                        Button("Upgrade to Pro") {
                            dismiss()
                            showPaywall = true
                        }
                    }
                    Button("Restore Purchases") { Task { await store.restore() } }
                }
                Section {
                    LabeledContent("Anonymous ID") {
                        Text(UserIdentity.current.uuidString.lowercased())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Catchline doesn’t need an account. This random ID is only used to track usage time; send it to us if you want your records deleted.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var planName: String {
        switch captioner.plan?.kind {
        case .trial: String(localized: "Free trial")
        case .paid: store.activeTransaction?.productID == AppConfig.yearlyProductID ? String(localized: "Pro Yearly") : String(localized: "Pro Monthly")
        case .free, nil: String(localized: "Free (3 minutes a day)")
        }
    }

    private func remainingText(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(localized: "\(String(format: "%.1f", Double(seconds) / 3600)) hours")
            : String(localized: "\(String(seconds / 60)) min \(String(format: "%02d", seconds % 60)) s")
    }
}
