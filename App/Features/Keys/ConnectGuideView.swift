import HyperVaultKit
import SwiftUI

/// One app's steps, as the server's registry words them: what it is, the steps, the strings to paste
/// (each with its own copy button), how to check it worked, the notes and where it all came from. An
/// untested entry says so before anything else; a client that takes the key only inside a URL says the
/// URL is the key.
struct ConnectGuideView: View {
    let guide: ConnectGuide
    let info: AgentClientInfo
    /// The real key the strings carry, when there is one: a string that holds it is copied as a secret.
    let key: String?

    @State private var notesOverride: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            header
            if !guide.steps.isEmpty { stepsSection }
            if !guide.pastes.isEmpty { pastesSection }
            if let check = guide.check, !check.isEmpty { checkSection(check) }
            if !guide.caveats.isEmpty { notesSection }
            if !guide.sources.isEmpty { sourcesSection }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            sectionTitle("Setup for \(guide.name.isEmpty ? info.name : guide.name)")
            HStack(spacing: HV.Space.xs) {
                HVTag(text: info.lane.shortLabel, tint: Palette.blue)
                if info.keyInUrl { HVTag(text: "Key in the URL", tint: Palette.warning) }
                if !info.verified { HVTag(text: "Untested", tint: Palette.warning) }
            }
            if let lane = guide.lane, let method = guide.keyMethod {
                Text("\(lane). \(method).")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if guide.isUntested || !info.verified {
                KeysNotice(text: guide.status ?? ConnectCopy.untestedNote)
            } else if let status = guide.status {
                Text(status)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            sectionTitle(ConnectCopy.stepsHeading)
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
                    Text("\(index + 1)")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(Palette.sky)
                        .frame(width: 26, height: 26)
                        .background(Palette.blue.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    Text(step)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1). \(step)")
            }
        }
    }

    // MARK: Strings to paste

    private var pastesSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            sectionTitle(ConnectCopy.pasteHeading)
            if info.keyInUrl || guide.warning != nil {
                KeysNotice(text: guide.warning ?? ConnectCopy.urlKeyWarning)
            }
            ForEach(guide.pastes) { paste in
                pasteBlock(paste)
            }
        }
    }

    private func pasteBlock(_ paste: ConnectGuide.Paste) -> some View {
        let isSecret = key.map { paste.text.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(paste.label)
                .font(.hvFootnote.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            pasteBody(paste)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(paste.label). Code, \(isSecret ? "holds your key" : "\(paste.text.split(separator: "\n").count) lines").")
                .keysHidesWhenInactive(isSecret)
            KeysCopyButton(title: ConnectCopy.copyLabel, text: paste.text, isSecret: isSecret)
        }
    }

    /// A message or an address wraps, as prose does; code keeps its lines and scrolls sideways, exactly as shown.
    @ViewBuilder
    private func pasteBody(_ paste: ConnectGuide.Paste) -> some View {
        if paste.language == "text" {
            Text(paste.text)
                .font(.hvMono)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(HV.Space.s + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(paste.text)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(HV.Space.s + 2)
            }
        }
    }

    // MARK: Check, notes, sources

    private func checkSection(_ check: String) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            sectionTitle(ConnectCopy.checkHeading)
            Text(check)
                .font(.hvCallout)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Open for the entries whose notes decide whether the setup works at all. Not a DisclosureGroup: its
    /// chevron is drawn bold in the primary colour, heavier than every other disclosure mark in the app.
    private var notesSection: some View {
        let isOpen = notesOverride ?? (!info.verified || info.keyInUrl)
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            Button {
                HV.Motion.animate { notesOverride = !isOpen }
            } label: {
                HStack {
                    sectionTitle(ConnectCopy.notesHeading)
                    Spacer(minLength: HV.Space.xs)
                    KeysChevron(isOpen: isOpen)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    ForEach(Array(guide.caveats.enumerated()), id: \.offset) { _, caveat in
                        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                            Text("\u{2022}").foregroundStyle(Palette.textTertiary)
                            Text(caveat)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, HV.Space.xs)
            }
        }
        .hvCard()
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            sectionTitle(ConnectCopy.sourcesHeading)
            ForEach(guide.sources, id: \.self) { source in
                if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                    Link(source, destination: url)
                        .font(.hvCaption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(minHeight: 44, alignment: .leading)
                } else {
                    Text(source).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .accessibilityAddTraits(.isHeader)
    }
}
