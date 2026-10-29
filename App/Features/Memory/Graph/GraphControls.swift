import SwiftUI

// What the Library's graph and the Memory map share above the picture: a box to find a node by name, a pill for each kind
// of node that can be left off, and the chip that leaves out what has no links. Both take plain values and closures, not
// either screen's model, so the two screens look and answer alike and only their words and identifiers differ.

/// A kind of node a pill can switch off: its name, and how many of it the graph holds.
struct GraphFilterType: Identifiable, Equatable {
    let name: String
    let count: Int

    var id: String { name }
}

/// The box, the pills and the chip above a graph.
struct GraphControls: View {
    /// What the box says when it is empty, and what VoiceOver calls it.
    let searchTitle: String
    @Binding var query: String
    /// The start of the identifiers: `<prefix>.search`, `<prefix>.type.<name>` and `<prefix>.unlinked`.
    let identifierPrefix: String
    /// One pill for each kind of node on offer, with how many of it there are.
    let types: [GraphFilterType]
    let hiddenTypes: Set<String>
    let hideUnlinked: Bool
    let onToggleType: (String) -> Void
    let onToggleUnlinked: () -> Void

    var body: some View {
        VStack(spacing: HV.Space.xxs) {
            searchField
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HV.Space.hair) {
                    ForEach(types) { type in
                        HVFilterPill(title: type.name, count: type.count, isSelected: !hiddenTypes.contains(type.name)) {
                            onToggleType(type.name)
                        }
                        .accessibilityIdentifier("\(identifierPrefix).type.\(type.name)")
                        .accessibilityHint(hiddenTypes.contains(type.name) ? "Shows them on the map" : "Leaves them off the map")
                    }
                    Button {
                        Haptics.select()
                        onToggleUnlinked()
                    } label: {
                        HVChip(title: "Hide unlinked", symbol: "eye.slash", isSelected: hideUnlinked)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide unlinked")
                    .accessibilityAddTraits(hideUnlinked ? .isSelected : [])
                    .accessibilityIdentifier("\(identifierPrefix).unlinked")
                    .padding(.leading, HV.Space.xs)
                }
                .padding(.horizontal, HV.Space.m)
            }
        }
        .padding(.top, HV.Space.xs)
    }

    private var searchField: some View {
        HStack(spacing: HV.Space.xs) {
            HVIcon("magnifyingglass").foregroundStyle(Palette.textTertiary)
            TextField(searchTitle, text: $query, prompt: Text.hvPrompt(searchTitle))
                .accessibilityIdentifier("\(identifierPrefix).search")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, HV.Space.m)
        .frame(minHeight: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .padding(.horizontal, HV.Space.m)
    }
}

/// One thing the search found.
struct GraphSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    /// The word at the end of the row ("Memory", "Chat", "markdown").
    let detail: String
    let symbol: String
    let tint: Color
}

/// What the search found, laid over the map: the best connected first, as the screen gives them. Tapping a row opens it, as
/// a tap on its node does. It scrolls inside a height of its own, so a few matches at a large text size do not push the map
/// away.
struct GraphSearchResults: View {
    let results: [GraphSearchResult]
    let onOpen: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if results.isEmpty {
                    Text("Nothing on the map has that in its name.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HV.Space.m)
                        .padding(.vertical, HV.Space.s)
                }
                ForEach(results) { result in
                    row(result)
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func row(_ result: GraphSearchResult) -> some View {
        Button { onOpen(result.id) } label: {
            HStack(spacing: HV.Space.s) {
                Image(systemName: result.symbol)
                    .foregroundStyle(result.tint)
                    .hvIconSlot(22)
                    .accessibilityHidden(true)
                Text(result.title)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: HV.Space.xs)
                Text(result.detail)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, HV.Space.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.title), \(result.detail)")
        .accessibilityHint("Opens it")
    }
}
