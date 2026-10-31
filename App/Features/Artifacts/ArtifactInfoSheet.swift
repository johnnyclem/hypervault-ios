import HyperVaultKit
import SwiftUI

/// Things laid out in a line that wraps: tags.
struct ArtifactFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: proposal.width ?? max(widest, 0), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The page's settings and facts in one place: who can open it, its icon, its
/// tags and prompt, and the way to its passwords.
struct ArtifactInfoSheet: View {
    let detail: ArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var glyph: String
    @State private var savingIcon = false
    @State private var askPublic = false

    init(detail: ArtifactDetailModel) {
        self.detail = detail
        _glyph = State(initialValue: detail.summary?.icon ?? "")
    }

    private var summary: ArtifactSummary? { detail.summary }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                if detail.canManage, let visibility = summary?.visibility {
                    accessSection(current: visibility)
                    if !detail.summaryIsPlaceholder, !detail.isGroup { iconSection }
                }
                if let tags = summary?.tags, !tags.isEmpty { tagsSection(tags) }
                if let prompt = summary?.sourcePrompt, !prompt.isEmpty { promptSection(prompt) }
                if detail.canManage { pinSection }
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Make this public?", isPresented: $askPublic, titleVisibility: .visible) {
                Button("Make public") { change(to: .public) }
            } message: {
                Text("Anyone with the link can open it.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: HV.Space.m) {
                ArtifactGlyph(slug: detail.slug, title: detail.title, icon: summary?.icon, size: 52)
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    Text(detail.title).font(.hvTitle3).lineLimit(2)
                    Text(subtitle).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.vertical, HV.Space.xxs)
            .accessibilityElement(children: .combine)
        }
        .hvListRow()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let summary { parts.append(summary.typeName) }
        if let date = summary?.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func accessSection(current: ArtifactVisibility) -> some View {
        Section {
            ForEach(ArtifactVisibility.allCases, id: \.self) { option in
                Button {
                    choose(option, current: current)
                } label: {
                    HStack(spacing: HV.Space.s) {
                        HVIconBadge(symbol: option.symbol, tint: option.tint, size: 32)
                        VStack(alignment: .leading, spacing: HV.Space.xxs) {
                            Text(option.title).font(.hvBody).foregroundStyle(Palette.textPrimary)
                            Text(option.detail).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer(minLength: HV.Space.xs)
                        if option == current {
                            HVIcon("checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == current ? .isSelected : [])
            }
            if current == .password {
                NavigationLink {
                    ArtifactPasswordsScreen(client: detail.env.client, slug: detail.slug)
                } label: {
                    Label("Passwords", systemImage: "key.horizontal").hvRowLabel()
                }
            }
        } header: {
            HVSectionHeader(title: "Who can open it")
        } footer: {
            if current == .private { Text("People you add by email can open it too.").hvSectionNote() }
        }
        .hvListRow()
    }

    private var iconSection: some View {
        Section {
            HStack(spacing: HV.Space.s) {
                ArtifactGlyph(slug: detail.slug, title: detail.title, icon: glyph, size: 36)
                TextField("Icon", text: $glyph, prompt: artifactPrompt(ArtifactIcon.initial(detail.title)))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: glyph) { _, value in
                        if let clipped = ArtifactIcon.normalizedGlyph(value), clipped != value { glyph = clipped }
                    }
                if savingIcon {
                    ProgressView()
                } else {
                    Button("Save") { saveIcon(glyph) }
                        .buttonStyle(.hvGhost)
                        .disabled(ArtifactIcon.normalizedGlyph(glyph) == ArtifactIcon.normalizedGlyph(summary?.icon))
                }
            }
            if summary?.icon != nil {
                Button("Back to the automatic icon") {
                    glyph = ""
                    saveIcon(nil)
                }
            }
        } header: {
            HVSectionHeader(title: "Icon")
        } footer: {
            Text("A letter or an emoji. It shows when the page is added to a home screen.").hvSectionNote()
        }
        .hvListRow()
    }

    private func tagsSection(_ tags: [String]) -> some View {
        Section {
            ArtifactFlowLayout {
                ForEach(tags, id: \.self) { tag in HVTag(text: "#\(tag)") }
            }
            .padding(.vertical, HV.Space.xxs)
        } header: {
            HVSectionHeader(title: "Tags")
        }
        .hvListRow()
    }

    private func promptSection(_ prompt: String) -> some View {
        Section {
            DisclosureGroup("Source prompt") {
                Text(prompt)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                Button {
                    ArtifactPasteboard.copy(prompt)
                    Haptics.tap()
                    app.toasts.show("Copied", style: .info)
                } label: {
                    Label("Copy prompt", systemImage: HVSymbol.copy).hvRowLabel()
                }
            }
        }
        .hvListRow()
    }

    private var pinSection: some View {
        Section {
            Toggle(isOn: Binding(get: { detail.isPinned }, set: { _ in Task { await detail.togglePin(toasts: app.toasts) } })) {
                Label("Pin to Library", systemImage: "pin").hvRowLabel()
            }
        }
        .hvListRow()
    }

    private var aboutSection: some View {
        Section {
            if let summary {
                if summary.isJsx { aboutRow("React page", "It runs as a page of its own.") }
                if summary.isPwa { aboutRow("Installable", "It can be added to a home screen from Safari.") }
            }
            aboutRow("Address", detail.link().absoluteString)
        } header: {
            HVSectionHeader(title: "About")
        }
        .hvListRow()
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(title).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            Text(value).font(.hvCallout).textSelection(.enabled)
        }
        .padding(.vertical, HV.Space.xxs)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func choose(_ option: ArtifactVisibility, current: ArtifactVisibility) {
        guard option != current else { return }
        if option == .public { askPublic = true } else { change(to: option) }
    }

    private func change(to option: ArtifactVisibility) {
        Task { await detail.setVisibility(option, toasts: app.toasts) }
    }

    private func saveIcon(_ value: String?) {
        savingIcon = true
        Task {
            _ = await detail.setIcon(ArtifactIcon.normalizedGlyph(value), toasts: app.toasts)
            savingIcon = false
        }
    }
}
