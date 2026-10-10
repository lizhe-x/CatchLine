import SwiftUI

struct CaptionScreen: View {
    @Environment(Captioner.self) private var captioner
    @AppStorage(Prefs.sourceLang) private var sourceLang = "en"
    @AppStorage(Prefs.targetLang) private var targetLang = "zh"
    @AppStorage(Prefs.fontScale) private var fontScale = 1.0
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.background) private var background = ""
    @State private var showSettings = false
    @State private var confirmNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CaptionList(transcript: captioner.transcript, fontScale: fontScale, waiting: captioner.status == .live)
            if let message = captioner.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(captioner.status == .error || captioner.status == .needsSignIn ? .red : .secondary)
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
            SettingsSheet()
        }
        .confirmationDialog("开始新会话会清空当前字幕", isPresented: $confirmNewSession, titleVisibility: .visible) {
            Button("清空并开始", role: .destructive) { start() }
        } message: {
            Text("可以先导出再开始。")
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
                .accessibilityLabel("缩小字号")
            Button("A+") { fontScale = min(2.2, ((fontScale + 0.1) * 10).rounded() / 10) }
                .accessibilityLabel("放大字号")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(captioner.status.isActive)
            .accessibilityLabel("设置")
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
                    Text("停止").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(captioner.status == .stopping)
            } else {
                Button {
                    if captioner.transcript.isEmpty { start() } else { confirmNewSession = true }
                } label: {
                    Text(captioner.transcript.isEmpty ? "开始" : "新会话").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                if !captioner.transcript.isEmpty, let file = exportFile() {
                    ShareLink(item: file) {
                        Label("导出", systemImage: "square.and.arrow.up").frame(minHeight: 50)
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
        case .error, .needsSignIn: .red
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

private struct CaptionList: View {
    let transcript: Transcript
    let fontScale: Double
    let waiting: Bool
    @State private var stickToBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if transcript.rows.isEmpty && transcript.liveSource.isEmpty {
                        Text(waiting ? "正在听…开始说话吧" : "字幕会显示在这里")
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
            } action: { _, atBottom in
                stickToBottom = atBottom
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
                        Label("回到最新", systemImage: "arrow.down")
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
