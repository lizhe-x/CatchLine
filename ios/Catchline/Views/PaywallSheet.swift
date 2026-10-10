import StoreKit
import SwiftUI

struct PaywallSheet: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(Captioner.self) private var captioner
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var error: String?

    /// In the trial and out of hours: upgrading to yearly starts it today.
    private var trialUsedUp: Bool {
        captioner.plan?.kind == .trial && (captioner.plan?.remainingSeconds ?? 1) <= 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if let yearly = store.yearly {
                        planButton(yearly, title: String(localized: "Yearly"), detail: yearlyDetail(yearly), badge: String(localized: "Save 50%"), prominent: true)
                    }
                    if let monthly = store.monthly, !trialUsedUp {
                        planButton(
                            monthly,
                            title: String(localized: "Monthly"),
                            detail: store.trialEligible ? String(localized: "7 days free, then \(monthly.displayPrice)/month") : String(localized: "\(monthly.displayPrice)/month"),
                            badge: store.trialEligible ? String(localized: "7-day free trial") : nil,
                            prominent: store.yearly == nil
                        )
                    }
                    if store.products.isEmpty {
                        if store.productsLoaded {
                            VStack(spacing: 10) {
                                Text("Subscriptions aren’t available right now.")
                                    .font(.subheadline)
                                if let loadError = store.loadError {
                                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Try Again") { Task { await store.load() } }
                                    .buttonStyle(.bordered)
                            }
                            .padding()
                        } else {
                            ProgressView().padding()
                        }
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Restore Purchases") { Task { await store.restore() } }
                        .font(.footnote)
                    fineprint
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onChange(of: store.isSubscribed) { _, subscribed in
            if subscribed && !trialUsedUp { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text(trialUsedUp ? "You’ve used your trial hours" as LocalizedStringKey : "Catchline Pro").font(.title2.bold())
            Text(trialUsedUp
                 ? "Looks like Catchline is really helping. Go yearly and it starts right away, so you can keep going." as LocalizedStringKey
                 : "Calls, meetings, conversations. Catch every word.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private func planButton(_ product: Product, title: String, detail: String, badge: String?, prominent: Bool) -> some View {
        Button {
            Task { await buy(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: .capsule)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(prominent ? .white.opacity(0.85) : .secondary)
                }
                Spacer()
                Text(product.displayPrice).font(.headline)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? .white : .primary)
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(store.purchasing)
    }

    private func yearlyDetail(_ yearly: Product) -> String {
        let perMonth = (yearly.price / 12).formatted(yearly.priceFormatStyle)
        return String(localized: "About \(perMonth)/month, starts now")
    }

    private var fineprint: some View {
        VStack(spacing: 8) {
            Text("Subscriptions include 40 hours a month (fair use; normal use won’t reach it). The free trial includes 3 hours. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period in Settings → Apple Account → Subscriptions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Terms of Use") { openURL(AppConfig.termsURL) }
                Button("Privacy Policy") { openURL(AppConfig.privacyURL) }
                Button("Fair Use Policy") { openURL(AppConfig.fairUseURL) }
            }
            .font(.caption2)
        }
    }

    private func buy(_ product: Product) async {
        do {
            error = nil
            if try await store.purchase(product) {
                await captioner.refreshPlan()
                if trialUsedUp == false { dismiss() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
