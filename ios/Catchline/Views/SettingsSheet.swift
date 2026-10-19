import StoreKit
import SwiftUI

struct SettingsSheet: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(Captioner.self) private var captioner
    @Binding var showPaywall: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.sourceLang) private var sourceLang = Language.auto
    @AppStorage(Prefs.targetLang) private var targetLang = Language.systemTarget
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.background) private var background = ""
    @AppStorage(Prefs.crossBorderConsent) private var crossBorderConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    NavigationLink {
                        LanguagePicker(title: "Language you’ll hear", selection: $sourceLang, allowsAuto: true,
                                       suggested: Language.likelySources(target: targetLang))
                    } label: {
                        LabeledContent("Listen to", value: sourceLang == Language.auto ? String(localized: "Auto-detect") : Language(code: sourceLang).label)
                    }
                    NavigationLink {
                        LanguagePicker(title: "Translate into", selection: $targetLang)
                    } label: {
                        LabeledContent("Translate into", value: Language(code: targetLang).label)
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
                    Button("Restore Purchases") { Task { _ = try? await store.restore(); await captioner.refreshPlan() } }
                }
                Section {
                    LabeledContent("Anonymous ID") {
                        Text(UserIdentity.current.uuidString.lowercased())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("CatchLine doesn’t need an account. This random ID is only used to track usage time; send it to us if you want your records deleted.")
                }
                if crossBorderConsent {
                    Section {
                        Button("Withdraw Consent", role: .destructive) {
                            crossBorderConsent = false
                            Task { await captioner.stop() }
                        }
                    } footer: {
                        Text("You agreed to audio being processed in the United States. After withdrawing, CatchLine asks again before captioning.")
                    }
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
