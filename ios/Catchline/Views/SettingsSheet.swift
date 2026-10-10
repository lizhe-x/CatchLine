import SwiftUI

struct SettingsSheet: View {
    @Environment(AuthService.self) private var auth
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
                if !AppConfig.useLocalMock {
                    Section("账号") {
                        if let email = auth.email {
                            LabeledContent("已登录", value: email)
                        }
                        Button("退出登录", role: .destructive) {
                            Task {
                                await auth.signOut()
                                dismiss()
                            }
                        }
                    }
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
}
