import StoreKit
import SwiftUI

struct SettingsSheet: View {
    @Environment(SubscriptionStore.self) private var store
    @Environment(Captioner.self) private var captioner
    @Binding var showPaywall: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.sourceLang) private var sourceLang = "en"
    @AppStorage(Prefs.targetLang) private var targetLang = "zh"
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.background) private var background = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("听", selection: $sourceLang) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                    Picker("翻译成", selection: $targetLang) {
                        ForEach(Language.all) { Text($0.label).tag($0.code) }
                    }
                }
                Section {
                    TextField("Mark Johnson, Acme Corp, W-2", text: $terms, axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("关键词")
                } footer: {
                    Text("人名、公司、术语，用逗号或换行分隔。")
                }
                Section {
                    TextField("和房东通电话，讨论续租和维修。", text: $background, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("背景说明（可选）")
                } footer: {
                    Text("关键词和背景会传给识别引擎，能明显提高专有名词的准确率。开始后不可修改。")
                }
                Section("订阅") {
                    LabeledContent("当前方案", value: planName)
                    if let plan = captioner.plan {
                        LabeledContent(plan.kind == .free ? "今日剩余" : "剩余时长", value: remainingText(plan.remainingSeconds))
                    }
                    if store.isSubscribed {
                        Button("管理订阅") {
                            Task {
                                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                                try? await AppStore.showManageSubscriptions(in: scene)
                            }
                        }
                    } else {
                        Button("升级到 Pro") {
                            dismiss()
                            showPaywall = true
                        }
                    }
                    Button("恢复购买") { Task { await store.restore() } }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var planName: String {
        switch captioner.plan?.kind {
        case .trial: "免费试用"
        case .paid: store.activeTransaction?.productID == AppConfig.yearlyProductID ? "Pro 年付" : "Pro 月付"
        case .free, nil: "免费版（每天 3 分钟）"
        }
    }

    private func remainingText(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%.1f 小时", Double(seconds) / 3600) : String(format: "%d 分 %02d 秒", seconds / 60, seconds % 60)
    }
}
