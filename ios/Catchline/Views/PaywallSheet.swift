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
                        planButton(yearly, title: "年付", detail: yearlyDetail(yearly), badge: "省 50%", prominent: true)
                    }
                    if let monthly = store.monthly, !trialUsedUp {
                        planButton(
                            monthly,
                            title: "月付",
                            detail: store.trialEligible ? "前 7 天免费，之后 \(monthly.displayPrice)/月" : "\(monthly.displayPrice)/月",
                            badge: store.trialEligible ? "7 天免费试用" : nil,
                            prominent: store.yearly == nil
                        )
                    }
                    if store.products.isEmpty {
                        ProgressView().padding()
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("恢复购买") { Task { await store.restore() } }
                        .font(.footnote)
                    fineprint
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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
            Text(trialUsedUp ? "试用额度已用完" : "Catchline Pro").font(.title2.bold())
            Text(trialUsedUp
                 ? "看来你真的很需要 Catchline。开通年付立即生效，马上继续使用。"
                 : "电话、会议、面对面交谈，每个词都跟得上。")
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
        return "约 \(perMonth)/月，立即生效"
    }

    private var fineprint: some View {
        VStack(spacing: 8) {
            Text("订阅含每月 40 小时（合理使用，正常使用基本不会达到）。免费试用期内含 3 小时。订阅会自动续期，可随时在 设置 → Apple 账户 → 订阅 中取消，需在当期结束前至少 24 小时取消。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("使用条款") { openURL(AppConfig.termsURL) }
                Button("隐私政策") { openURL(AppConfig.privacyURL) }
                Button("合理使用政策") { openURL(AppConfig.fairUseURL) }
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
