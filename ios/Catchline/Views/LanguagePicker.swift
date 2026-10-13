import SwiftUI

/// Searchable list of every Soniox language, suggestions first.
struct LanguagePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    /// Offer "Auto-detect" at the top (listening language only).
    var allowsAuto = false
    var suggested: [String] = []
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if query.isEmpty {
                if allowsAuto {
                    Section {
                        row(Language.auto, label: Text("Auto-detect"))
                    }
                }
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested, id: \.self) { code in
                            row(code, label: Text(Language(code: code).label))
                        }
                    }
                }
            }
            Section {
                ForEach(matches) { language in
                    row(language.code, label: Text(language.label))
                }
            } header: {
                if query.isEmpty { Text("All Languages") }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [Language] {
        let all = Language.all
        guard !query.isEmpty else { return all }
        return all.filter { $0.label.localizedStandardContains(query) || $0.code.hasPrefix(query.lowercased()) }
    }

    private func row(_ code: String, label: Text) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                label
                Spacer()
                if selection == code {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
        }
        .tint(.primary)
    }
}

/// "Translate into" + "Language you'll hear" form sections, shared by the
/// first-launch screen and the language sheet on the caption screen.
struct LanguageSections: View {
    @Binding var sourceLang: String
    @Binding var targetLang: String

    var body: some View {
        let likely = Language.likelySources(target: targetLang)
        Section {
            NavigationLink {
                LanguagePicker(title: "Translate into", selection: $targetLang, suggested: targetSuggestions)
            } label: {
                Text(Language(code: targetLang).label)
            }
        } header: {
            Text("Translate into")
        }
        Section {
            choice(Language.auto, Text("Auto-detect"))
            ForEach(quickSources(likely), id: \.self) { code in
                choice(code, Text(Language(code: code).label))
            }
            NavigationLink {
                LanguagePicker(title: "Language you’ll hear", selection: $sourceLang, allowsAuto: true, suggested: likely)
            } label: {
                Text("More Languages…")
            }
        } header: {
            Text("Language you’ll hear")
        } footer: {
            if sourceLang == targetLang {
                Text("Same language: captions only, no translation.")
            } else {
                Text("Optional. Picking the language you’ll hear makes captions more accurate. Auto-detect works for any language, even mixed.")
            }
        }
    }

    /// Up to three likely languages, plus the current pick if it's elsewhere.
    private func quickSources(_ likely: [String]) -> [String] {
        var codes = Array(likely.prefix(3))
        if sourceLang != Language.auto, !codes.contains(sourceLang) { codes.append(sourceLang) }
        return codes
    }

    private var targetSuggestions: [String] {
        var seen = Set<String>()
        return ([Language.systemTarget] + Locale.preferredLanguages.compactMap(Language.sonioxCode(for:)))
            .filter { seen.insert($0).inserted }
    }

    private func choice(_ code: String, _ label: Text) -> some View {
        Button {
            sourceLang = code
        } label: {
            HStack {
                label
                Spacer()
                if sourceLang == code {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
        }
        .tint(.primary)
    }
}

/// First launch: pick languages before anything else.
struct OnboardingView: View {
    @AppStorage(Prefs.sourceLang) private var sourceLang = Language.auto
    @AppStorage(Prefs.targetLang) private var targetLang = Language.systemTarget
    @AppStorage(Prefs.onboarded) private var onboarded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Choose Your Languages")
                            .font(.title2.bold())
                        Text("CatchLine listens and shows live captions, translated into your language.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                LanguageSections(sourceLang: $sourceLang, targetLang: $targetLang)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    // Persist the defaults too, so they don't shift with the system language later.
                    UserDefaults.standard.set(sourceLang, forKey: Prefs.sourceLang)
                    UserDefaults.standard.set(targetLang, forKey: Prefs.targetLang)
                    onboarded = true
                } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }
}

/// Language sheet opened from the caption screen's language bar.
struct LanguageSheet: View {
    @Binding var sourceLang: String
    @Binding var targetLang: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LanguageSections(sourceLang: $sourceLang, targetLang: $targetLang)
            }
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
