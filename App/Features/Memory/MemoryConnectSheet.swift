import HyperVaultKit
import SwiftUI

/// Join this memory to another memory, or to a page, by hand. The graph shows
/// it as a strong link. Memory links are kept on main.
struct MemoryConnectSheet: View {
    let model: MemoryDetailModel
    let memory: MemoryFull
    /// What it is linked to already, which is not offered again.
    let linked: Set<String>

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var memories: [MemoryItem] = []
    @State private var pages: [MemoryGraphArtifact] = []
    @State private var isLoading = true
    @State private var connecting: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HV.Space.xs) {
                    MemorySearchField(text: $query, prompt: "Find something to link")
                    if isLoading && memories.isEmpty {
                        HVListSkeleton(rows: 5)
                    } else if shownMemories.isEmpty && shownPages.isEmpty {
                        HVEmptyState(symbol: "link", title: "Nothing to link", message: "Nothing else matches. Keep more, or try other words.")
                    }
                    if !shownMemories.isEmpty {
                        HVSectionHeader(title: "Memories").padding(.top, HV.Space.s)
                        MemoryRowStack(items: shownMemories) { item in
                            row(id: item.id, kind: .memory, title: item.title, subtitle: item.summary)
                        }
                    }
                    if !shownPages.isEmpty {
                        HVSectionHeader(title: "Pages").padding(.top, HV.Space.s)
                        MemoryRowStack(items: shownPages) { page in
                            row(id: page.id, kind: .page, title: page.title, subtitle: nil)
                        }
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("Link \u{201C}\(memory.title)\u{201D}")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    private var shownMemories: [MemoryItem] {
        let candidates = memories.filter { $0.id != memory.id && !linked.contains($0.id) }
        return Array(MemoryRecallScorer.rank(query, in: candidates).prefix(60))
    }

    private var shownPages: [MemoryGraphArtifact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = pages.filter { !linked.contains($0.id) }
        if trimmed.isEmpty { return Array(candidates.prefix(30)) }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func row(id: String, kind: KeptKind, title: String, subtitle: String?) -> some View {
        Button {
            connect(id)
        } label: {
            HVRow(symbol: kind.symbol, tint: kind.tint, title: title, subtitle: subtitle) {
                if connecting == id { ProgressView() } else { Image(systemName: "plus.circle").foregroundStyle(Color.accentColor) }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(connecting != nil)
        .accessibilityLabel("Link to \(title)")
    }

    private func load() async {
        let client = model.client
        let main = MindBranchName.defaultName
        do {
            let stream = model.env.load("memory.list.\(main)") { try await client.send(.memoryList(branch: main)) }
            for try await loaded in stream {
                memories = loaded.value.memories
                isLoading = false
            }
        } catch {
            isLoading = false
        }
        if let list = try? await client.send(.yours(filter: .file, limit: 50)) {
            pages = list.results.map { MemoryGraphArtifact(id: $0.id, title: $0.name, slug: $0.slug) }
        }
    }

    private func connect(_ target: String) {
        connecting = target
        Task {
            do {
                let message = try await model.connect(to: target)
                connecting = nil
                Haptics.success()
                app.toasts.success(message)
                dismiss()
            } catch {
                connecting = nil
                app.toasts.show(error: error)
            }
        }
    }
}
