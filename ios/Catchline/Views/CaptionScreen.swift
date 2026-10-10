import SwiftUI

struct CaptionScreen: View {
    @Environment(Captioner.self) private var captioner
    @AppStorage(Prefs.sourceLang) private var sourceLang = "en"
    @AppStorage(Prefs.targetLang) private var targetLang = Language.defaultTarget
    @AppStorage(Prefs.fontScale) private var fontScale = 1.0
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.background) private var background = ""
    @State private var showSettings = false
    @State private var showPaywall = false
    @State private var confirmNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            header
            AllowanceBar { showPaywall = true }
            Divider()
            CaptionList(transcript: captioner.transcript, fontScale: fontScale, waiting: captioner.status == .live)
            if let message = captioner.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(captioner.status == .error ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: .rect(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            controls
        }
        .task {
            if AppConfig.autoStart && captioner.status == .idle { start() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(showPaywall: $showPaywall)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallSheet()
        }
        .onChange(of: captioner.status) { _, status in
            if status == .quotaExhausted { showPaywall = true }
        }
        .confirmationDialog("Starting a new session clears the current captions", isPresented: $confirmNewSession, titleVisibility: .visible) {
            Button("Clear and Start", role: .destructive) { start() }
        } message: {
            Text("You can export them first.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35]) { dot, phase in
                    dot.opacity(captioner.status == .live ? phase : 1)
                } animation: { _ in .easeInOut(duration: 0.8) }
            Text(captioner.status.label).font(.subheadline).foregroundStyle(.secondary)
            if let startedAt = captioner.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatElapsed((captioner.endedAt ?? context.date).timeIntervalSince(startedAt)))
                        .font(.subheadline.monospacedDigit())
                }
            }
            Spacer()
            Button("A−") { fontScale = max(0.8, ((fontScale - 0.1) * 10).rounded() / 10) }
                .accessibilityLabel("Smaller text")
            Button("A+") { fontScale = min(2.2, ((fontScale + 0.1) * 10).rounded() / 10) }
                .accessibilityLabel("Larger text")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(captioner.status.isActive)
            .accessibilityLabel("Settings")
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if captioner.status.isActive || captioner.status == .stopping {
                Button(role: .destructive) {
                    Task { await captioner.stop() }
                } label: {
                    Text("Stop").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(captioner.status == .stopping)
            } else {
                Button {
                    if captioner.transcript.isEmpty { start() } else { confirmNewSession = true }
                } label: {
                    Text(captioner.transcript.isEmpty ? "Start" as LocalizedStringKey : "New Session").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                if captioner.status == .quotaExhausted {
                    Button {
                        showPaywall = true
                    } label: {
                        Text("Upgrade").frame(minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                }
                if !captioner.transcript.isEmpty, let file = exportFile() {
                    ShareLink(item: file) {
                        Label("Export", systemImage: "square.and.arrow.up").frame(minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch captioner.status {
        case .live: .green
        case .starting, .reconnecting, .interrupted, .stopping: .orange
        case .error, .quotaExhausted: .red
        case .idle: .gray
        }
    }

    private func start() {
        let settings = CaptionSettings(sourceLang: sourceLang, targetLang: targetLang, terms: terms, background: background)
        Task { await captioner.start(with: settings) }
    }

    private func exportFile() -> URL? {
        guard let startedAt = captioner.startedAt else { return nil }
        let text = captioner.transcript.exportText(startedAt: startedAt, sourceLang: sourceLang, targetLang: targetLang)
        let stamp = startedAt.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        let url = FileManager.default.temporaryDirectory.appending(path: "catchline-\(stamp).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// "今日 2:40" / "试用 2:58:10" / "本月 39.5h" — counts down live while streaming.
/// "Left today: 2m 30s  [Upgrade to Pro]" — counts down live while streaming.
private struct AllowanceBar: View {
    @Environment(Captioner.self) private var captioner
    var onUpgrade: () -> Void

    var body: some View {
        if let plan = captioner.plan {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = captioner.remainingSeconds(at: context.date) ?? plan.remainingSeconds
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(label(plan.kind, left)).monospacedDigit()
                    Spacer()
                    if plan.kind == .free {
                        Button("Upgrade to Pro", action: onUpgrade)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
                .font(.footnote)
                .foregroundStyle(left < 60 ? .orange : .secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private func label(_ kind: PlanStatus.Kind, _ seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        switch kind {
        case .free:
            let text = duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, zeroValueUnits: .show(length: 1)))
            return String(localized: "Left today: \(text)")
        case .trial:
            let text = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            return String(localized: "Trial time left: \(text)")
        case .paid:
            let text = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            return String(localized: "Left this month: \(text)")
        }
    }
}

private struct CaptionList: View {
    let transcript: Transcript
    let fontScale: Double
    let waiting: Bool
    @State private var stickToBottom = true
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if transcript.rows.isEmpty && transcript.liveSource.isEmpty {
                        Text(waiting ? "Listening… start talking" as LocalizedStringKey : "Captions will appear here")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 200)
                    }
                    ForEach(transcript.rows) { row in
                        let isLast = row.id == transcript.rows.last?.id
                        let liveHere = isLast && !row.closed && row.target.isEmpty
                        CaptionRowView(
                            source: row.source,
                            target: row.target,
                            liveSource: liveHere ? transcript.liveSource : "",
                            liveTarget: liveHere ? transcript.liveTarget : "",
                            fontScale: fontScale
                        )
                        Divider()
                    }
                    if let last = transcript.rows.last, last.closed || !last.target.isEmpty,
                       !transcript.liveSource.isEmpty || !transcript.liveTarget.isEmpty {
                        CaptionRowView(source: "", target: "", liveSource: transcript.liveSource, liveTarget: transcript.liveTarget, fontScale: fontScale)
                    } else if transcript.rows.isEmpty, !transcript.liveSource.isEmpty {
                        CaptionRowView(source: "", target: "", liveSource: transcript.liveSource, liveTarget: transcript.liveTarget, fontScale: fontScale)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, isAtBottom in
                // New captions make the content taller before we scroll, which
                // briefly reads as "not at bottom" — that must not unstick.
                // Only the user's own drags decide (see onScrollPhaseChange).
                atBottom = isAtBottom
                if isAtBottom { stickToBottom = true }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .interacting {
                    stickToBottom = false
                } else if newPhase == .idle, oldPhase != .idle {
                    stickToBottom = atBottom
                }
            }
            .onChange(of: transcript.rows) { scrollIfSticky(proxy) }
            .onChange(of: transcript.liveSource) { scrollIfSticky(proxy) }
            .onChange(of: fontScale) { scrollIfSticky(proxy) }
            .overlay(alignment: .bottom) {
                if !stickToBottom {
                    Button {
                        stickToBottom = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(.capsule)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func scrollIfSticky(_ proxy: ScrollViewProxy) {
        guard stickToBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

private struct CaptionRowView: View {
    let source: String
    let target: String
    let liveSource: String
    let liveTarget: String
    let fontScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(source) + Text(source.isEmpty ? liveSource.trimmingCharacters(in: .whitespaces) : liveSource).foregroundStyle(.tertiary))
                .font(.system(size: 22 * fontScale, weight: .medium))
            if !target.isEmpty || !liveTarget.isEmpty {
                (Text(target) + Text(liveTarget).foregroundStyle(.tertiary))
                    .font(.system(size: 18 * fontScale))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10 * fontScale)
        .textSelection(.enabled)
    }
}
