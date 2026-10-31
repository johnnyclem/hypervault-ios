import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// Import: bring a ChatGPT, Claude, Gemini or Grok history into the vault, then
/// continue any thread in Chat on any backend.
struct ImportRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ImportScreen(client: env.client, importBytes: env.limits.importBytes)
    }
}

struct ImportScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: ImportModel
    @State private var picking = false
    @FocusState private var pasteFocused: Bool
    /// The Stop button is what VoiceOver is on while an import runs, and it goes when the import ends.
    @AccessibilityFocusState private var resultFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(client: HVClient, importBytes: Int) {
        _model = State(initialValue: ImportModel(client: client, importBytes: importBytes))
    }

    /// For previews, which need a model already part way.
    init(model: ImportModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                // Said once, where the choice is made. Every later step has its own heading.
                if model.stage == .choose { intro }
                switch model.stage {
                case .choose: choose
                case .reading: reading
                case .review: review
                case .sending: sending
                case .done: done
                case .stopped(let reason): stopped(reason)
                }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
            .hvAnimation(.easeInOut(duration: 0.2), value: model.stage)
        }
        .onChange(of: model.stage) { _, stage in
            switch stage {
            case .done, .stopped: resultFocused = true
            default: break
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pinsChooseAction, let source = model.source { chooseAction(source).hvActionBar() }
        }
        .hvScreenBackground()
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.json, .zip, .plainText, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.read(urls)
            case .failure(let error): app.toasts.show(error: error)
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Import your AI history").font(.hvTitle)
            Text("Pull your full history out of any LLM and into your vault. Then continue any thread on any backend in Chat.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Choose

    private var choose: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                HVSectionHeader(title: "Where is it from?")
                // Two or three cards across while their names fit. At an accessibility size one card takes the width: in half of
                // it a name is broken in two ("Gem-/ini", "An-/thropic").
                LazyVGrid(
                    columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())]
                        : [GridItem(.adaptive(minimum: 150), spacing: HV.Space.s)],
                    spacing: HV.Space.s
                ) {
                    ForEach(ImportPlatform.allCases) { platform in
                        ImportSourceCard(platform: platform, isSelected: model.source == platform) {
                            model.source = platform
                            Haptics.select()
                        }
                    }
                }
            }

            if let source = model.source {
                ImportGuideCard(guide: source.guide)
                if source == .other { pasteArea }
                if !pinsChooseAction { chooseAction(source) }
                if let error = model.readError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").hvRowLabel()
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.danger)
                }
            } else {
                Text("Pick a service to see how to get its export.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    /// The step after choosing a service. The guide above it runs longer than the screen, so the button
    /// is pinned under the scroll, where it is always in reach. At the largest text sizes a pinned bar
    /// would take half the screen, so it goes back to the end of the page.
    private var pinsChooseAction: Bool {
        model.stage == .choose && model.source != nil && !dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private func chooseAction(_ source: ImportPlatform) -> some View {
        if source == .other {
            Button("Check what I pasted") {
                pasteFocused = false
                model.readPasted()
            }
            .buttonStyle(.hvPrimary)
            .disabled(model.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            VStack(spacing: HV.Space.xs) {
                Button("Choose the export file") { picking = true }
                    .buttonStyle(.hvPrimary)
                Text("The zip you downloaded, or \(source.exportFileName). You can choose several files at once.")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.pasted)
                    .focused($pasteFocused)
                    .scrollContentBackground(.hidden)
                    .font(.hvMono)
                    .frame(minHeight: 180)
                    .hvFieldChrome(isFocused: pasteFocused)
                    .accessibilityLabel("Pasted conversation")
                if model.pasted.isEmpty {
                    Text("User: how do I center a div\nAssistant: with flexbox…")
                        .font(.hvMono)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, HV.Space.m + 5)
                        .padding(.vertical, HV.Space.s + 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { model.pasted = text }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                Spacer()
                Button("Pick a text file") { picking = true }.buttonStyle(.hvGhost)
            }
        }
    }

    // MARK: Reading

    private var reading: some View {
        VStack(spacing: HV.Space.m) {
            ProgressView().controlSize(.large)
            Text("Reading your export…").font(.hvHeadline)
            Text("A big zip can take a moment. Nothing leaves your phone yet.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { model.backToChoose() }.buttonStyle(.hvGhost)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HV.Space.xxl)
        .accessibilityElement(children: .combine)
    }

    // MARK: Review

    @ViewBuilder
    private var review: some View {
        if model.plan == nil {
            nothingFound
        } else {
            found
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                HStack(spacing: HV.Space.s) {
                    HVIconBadge(symbol: model.platform.guide.symbol, tint: model.platform.guide.tint, size: 44)
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        Text(model.isPaste ? "A pasted conversation" : "\(model.platform.title) history")
                            .font(.hvHeadline)
                        if let name = model.fileName {
                            Text(name).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        }
                        Text(foundSubtitle).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    }
                }
                if !model.sampleTitles.isEmpty {
                    Text("Includes " + model.sampleTitles.map { "“\($0)”" }.joined(separator: ", ") + (model.conversationCount > model.sampleTitles.count ? " and more." : "."))
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(model.notes, id: \.self) { note in
                    Text(note).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                }
                if let chosen = model.mismatchedChoice {
                    Label("You picked \(chosen.title), but this looks like \(model.platform.title). It will be imported as \(model.platform.title).",
                          systemImage: "info.circle")
                        .hvRowLabel()
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.warning)
                }
            }
            .hvCard()

            if model.isPaste {
                HVLabeledField(title: "Name it (optional)") {
                    TextField("Conversation name", text: $model.pasteTitle, prompt: Text.hvPrompt("A few words to find it by"))
                }
            }

            VStack(spacing: HV.Space.xs) {
                Button("Import \(model.conversationCount) conversation\(model.conversationCount == 1 ? "" : "s")") {
                    model.start()
                }
                .buttonStyle(.hvPrimary)
                Button("Choose something else") { model.backToChoose() }.buttonStyle(.hvGhost)
            }

            Text("Importing again is safe. A conversation you already imported is replaced, not copied.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var foundSubtitle: String {
        var parts = ["\(model.conversationCount) conversation\(model.conversationCount == 1 ? "" : "s")"]
        if let messages = model.documents.first?.messageCount, model.isPaste { parts = ["\(messages) message\(messages == 1 ? "" : "s")"] }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes), countStyle: .file))
        if model.partCount > 1 { parts.append("sent in \(model.partCount) parts") }
        return parts.joined(separator: " · ")
    }

    private var nothingFound: some View {
        VStack(spacing: HV.Space.m) {
            HVEmptyState(
                symbol: "doc.questionmark",
                title: "No conversations in there",
                message: model.readError ?? ImportInspector.nothingFoundMessage
            )
            ForEach(model.notes, id: \.self) { note in
                Text(note).font(.hvCaption).foregroundStyle(Palette.textTertiary).multilineTextAlignment(.center)
            }
            Button("Choose another file") { model.backToChoose() }.buttonStyle(.hvPrimary)
        }
    }

    // MARK: Sending

    private var sending: some View {
        let progress = model.progress
        return VStack(alignment: .leading, spacing: HV.Space.m) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Text("Importing…").font(.hvHeadline)
                ProgressView(value: progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Import progress")
                    .accessibilityValue("\(Int((progress?.fraction ?? 0) * 100)) percent. \(sendingLine(progress))")
                Text(sendingLine(progress)).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            .hvCard()
            Text("Keep HyperVault open. Large histories go in a few at a time and can take several minutes. If something interrupts it, you can pick up where it stopped.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textTertiary)
            Button("Stop") { model.stop() }.buttonStyle(.hvSecondary)
        }
    }

    private func sendingLine(_ progress: ImportProgress?) -> String {
        guard let progress, progress.conversationsTotal > 0 else { return "Getting started…" }
        var line = "\(progress.conversationsDone) of \(progress.conversationsTotal) conversations"
        if progress.batchesTotal > 1 {
            line += " · part \(min(progress.batchesDone + 1, progress.batchesTotal)) of \(progress.batchesTotal)"
        }
        return line
    }

    // MARK: Done

    private var done: some View {
        VStack(spacing: HV.Space.l) {
            ZStack {
                Circle().fill(Palette.mint.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: "checkmark").font(.system(size: 34, weight: .semibold)).foregroundStyle(Palette.mint)
            }
            .accessibilityHidden(true)
            VStack(spacing: HV.Space.xs) {
                Text("All in")
                    .font(.hvTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($resultFocused)
                Text(model.totals.summary(platform: model.platform))
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { counts }
                VStack(spacing: HV.Space.s) { counts }
            }
            .hvCard()
            .accessibilityElement(children: .combine)
            if model.totals.skipped > 0 {
                Text(skippedExplanation)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: HV.Space.xs) {
                // A link to a tab starts the tab from its first screen, so this closes Import where it was pushed on Chat too.
                Button("Open Chat") { app.router.open(.tab(.chat)) }.buttonStyle(.hvPrimary)
                Button("Import another") { model.startOver() }.buttonStyle(.hvGhost)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var skippedExplanation: String {
        var text = "Skipped conversations had nothing in them to import."
        if model.totals.tooLarge > 0 {
            text += " \(model.totals.tooLarge) \(model.totals.tooLarge == 1 ? "was" : "were") too large for the server to take."
        }
        return text
    }

    @ViewBuilder
    private var counts: some View {
        count(model.totals.imported, "Imported")
        count(model.totals.skipped, "Skipped")
        count(model.totals.messages, "Messages")
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(spacing: HV.Space.xxs) {
            Text(value.formatted()).font(.system(.title2, weight: .bold))
            Text(label).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stopped

    private func stopped(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Label("The import stopped", systemImage: "pause.circle.fill").hvRowLabel()
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.warning)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($resultFocused)
                Text(reason).font(.hvCallout).foregroundStyle(Palette.textSecondary)
                if let progress = model.progress, progress.conversationsTotal > 0 {
                    Text("\(model.totals.imported) conversation\(model.totals.imported == 1 ? " is" : "s are") already in, out of \(progress.conversationsTotal).")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .hvCard()
            VStack(spacing: HV.Space.xs) {
                Button("Continue") { model.resume() }.buttonStyle(.hvPrimary)
                Button("Start over") { model.startOver() }.buttonStyle(.hvGhost)
            }
        }
    }
}

/// One service on the choice grid.
struct ImportSourceCard: View {
    let platform: ImportPlatform
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                HVIconBadge(symbol: platform.guide.symbol, tint: platform.guide.tint, size: 36)
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    Text(platform.cardTitle).font(.hvHeadline).foregroundStyle(Palette.textPrimary)
                    Text(platform.cardSubtitle).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HV.Space.m)
            .frame(minHeight: 44)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Palette.border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("import.source.\(platform.rawValue)")
    }
}

/// "How to get your export", as numbered steps.
struct ImportGuideCard: View {
    let guide: ImportGuide

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Text(guide.headline).font(.hvHeadline)
            VStack(alignment: .leading, spacing: HV.Space.s) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: HV.Space.s) {
                        Text("\(index + 1)")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(guide.tint)
                            .frame(width: 24, height: 24)
                            .background(guide.tint.opacity(0.14), in: Circle())
                            .accessibilityHidden(true)
                        Text(step).font(.hvCallout).foregroundStyle(Palette.textPrimary)
                            .accessibilityLabel("Step \(index + 1). \(step)")
                    }
                }
            }
            if let footnote = guide.footnote {
                Text(footnote).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .hvCard()
    }
}

#if DEBUG
#Preview("Import") {
    PreviewHost { ImportRootView() }
}

#Preview("Review") {
    PreviewHost { ImportPreviewHost(stage: .review) }
}

/// A seeded Import screen for previews and snapshots.
struct ImportPreviewHost: View {
    enum Seed { case choose, paste, review, sending, done, stopped, nothing }

    @Environment(AppEnvironment.self) private var env
    let stage: Seed

    var body: some View {
        let model = ImportModel(client: env.client, importBytes: env.limits.importBytes)
        model.previewSeed(stage)
        return ImportScreen(model: model)
    }
}
#endif
