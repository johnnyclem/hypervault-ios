import HyperVaultKit
import SwiftUI

/// A group chat with several of your models. You talk to the room; the members
/// you address take turns, and hand work to each other with @mentions.
struct RoomScreen: View {
    let roomID: String
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatRoomContent(roomID: roomID, env: env).id(roomID)
    }
}

struct ChatRoomContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let env: AppEnvironment
    @State private var model: ChatRoomModel
    @State private var showMembers = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var windowSize = 60
    @FocusState private var focused: Bool

    private static let bottomID = "bottom"
    private static let pollSeconds: UInt64 = 4

    private var palette: ChatRoomPalette { ChatRoomPalette(members: model.members) }

    init(roomID: String, env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: ChatRoomModel(roomID: roomID, client: env.client))
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case .ready = model.phase { composer }
            }
            .hvScreenBackground()
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showMembers = true } label: { Label("Members", systemImage: "person.2") }
                        Button {
                            renameText = model.title
                            showRename = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete room", systemImage: HVSymbol.delete) }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Room menu")
                }
            }
            .sheet(isPresented: $showMembers) { ChatRoomMembersSheet(model: model, env: env) }
            .alert("Rename room", isPresented: $showRename) {
                TextField("Room name", text: $renameText, prompt: chatPrompt("Room name"))
                Button("Save") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this room?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete room", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The room and everything said in it are deleted. This can't be undone.")
            }
            .task { await model.load() }
            .task { await watch() }
    }

    /// While a round runs somewhere else (another device), look for what is new.
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            if model.header?.running == true, !model.isDriving { await model.refresh() }
        }
    }

    // MARK: Thread

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HVLoadingState(message: "Opening the room").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            thread
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    roster
                    if model.messages.isEmpty { emptyRoom }
                    if model.messages.count > windowSize {
                        Button("Show \(min(model.messages.count - windowSize, 60)) earlier") { windowSize += 60 }
                            .buttonStyle(.hvGhost)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    ForEach(model.messages.suffix(windowSize)) { message in
                        ChatRoomMessageView(message: message, members: model.members) { slug in
                            app.router.push(.artifact(slug: slug))
                        }
                    }
                    if let next = model.pending.first {
                        ChatTypingLine(next: next, later: Array(model.pending.dropFirst()), members: model.members, isRunning: model.isDriving)
                    }
                    if model.canContinue {
                        continueCard
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s)
                .hvReadableWidth()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { scroll(proxy) }
            .onChange(of: model.pending.count) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        HV.Motion.animate(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private var roster: some View {
        ChatFlowLayout(spacing: 6) {
            ForEach(model.members) { member in
                HStack(spacing: HV.Space.hair) {
                    Circle().fill(palette.color(for: member)).frame(width: 8, height: 8)
                    Text("@\(member.handle)").font(.hvCaption.weight(.medium))
                    if let name = member.backend?.defaultModel, !name.isEmpty {
                        Text(name).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, HV.Space.s)
                .padding(.vertical, HV.Space.hair)
                .background(Palette.surfaceRaised, in: Capsule())
                .accessibilityElement(children: .combine)
            }
            if !model.pending.isEmpty {
                Text("\(model.budget) turn\(model.budget == 1 ? "" : "s") left in this round")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.vertical, HV.Space.hair)
            }
        }
    }

    private var emptyRoom: some View {
        let handles = model.members.map { "@" + $0.handle }.joined(separator: ", ")
        return HVEmptyState(
            symbol: "person.3",
            title: "Nobody has spoken yet.",
            message: handles.isEmpty
                ? "Say something to the room."
                : "Address members by handle to give them work. Try: \u{201C}\(handles), introduce yourselves and say what you would own.\u{201D}"
        )
        .padding(.top, HV.Space.l)
    }

    private var continueCard: some View {
        HStack(spacing: HV.Space.s) {
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text("\(model.pending.count) turn\(model.pending.count == 1 ? "" : "s") still waiting")
                    .font(.hvFootnote.weight(.semibold))
                Text("Nobody is running this round.").font(.hvCaption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Continue") { model.resume() }.buttonStyle(.hvGhost).frame(minHeight: 44)
        }
        .padding(.horizontal, HV.Space.s)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var model = model
        return VStack(spacing: HV.Space.xs) {
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.hvFootnote).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.dismissNotice() } label: {
                        Image(systemName: HVSymbol.close).font(.hvCaption.weight(.bold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, HV.Space.s)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                mentionChips
                TextField("Message", text: $model.draft, prompt: Text(model.composerPrompt).foregroundStyle(Palette.textSecondary), axis: .vertical)
                    .accessibilityIdentifier("room.field")
                    .font(.hvBody)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, HV.Space.m)
                    .padding(.top, HV.Space.xs)
                    .padding(.bottom, HV.Space.xs)
                HStack(spacing: HV.Space.xs) {
                    Text(addressLine)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Spacer(minLength: 0)
                    if model.isDriving {
                        Button { model.stop() } label: { Image(systemName: "stop.fill") }
                            .buttonStyle(.hvIcon)
                            .accessibilityLabel("Stop")
                    } else if model.canSend {
                        Button {
                            Haptics.tap()
                            model.send()
                        } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.hvIconProminent)
                            .accessibilityLabel("Send")
                    }
                }
                .padding(.leading, HV.Space.m)
                .padding(.trailing, HV.Space.xs)
                .padding(.bottom, HV.Space.xs)
            }
            .hvGlass(radius: HV.Radius.floating)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.top, HV.Space.xs)
        .padding(.bottom, HV.Space.xs)
        .hvReadableWidth()
        .hvAnimation(.spring(response: 0.3, dampingFraction: 0.8), value: model.canSend)
        .hvAnimation(HV.Motion.entrance, value: model.notice)
    }

    private var mentionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                ForEach(model.members) { member in
                    Button { model.mention(member.handle) } label: {
                        ChatHandleChip(
                            handle: member.handle, color: palette.color(for: member),
                            font: .hvFootnote.weight(.medium), verticalPadding: 6
                        )
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(member.handle)")
                }
            }
            .padding(.horizontal, HV.Space.s)
        }
    }

    private var addressLine: String {
        let who = model.addressed
        if who.isEmpty { return "No one named: everyone answers, in order." }
        return "Goes to " + who.map { "@" + $0 }.joined(separator: ", ") + "."
    }

    // MARK: Actions

    private func rename() {
        let name = renameText
        Task {
            do { try await model.rename(to: name) } catch { app.toasts.show(error: error) }
        }
    }

    private func delete() {
        Task {
            do {
                try await model.delete()
                Haptics.success()
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Pieces

struct ChatRoomMessageView: View {
    let message: ChatRoomMessage
    let members: [ChatRoomMember]
    var onOpenPage: (String) -> Void

    var body: some View {
        switch message.senderKind {
        case .system:
            Text(message.content)
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, 6)
                .background(Palette.surfaceRaised, in: Capsule())
                .frame(maxWidth: .infinity)
        case .human:
            HStack(spacing: 0) {
                Spacer(minLength: 56)
                Text(message.content)
                    .font(.hvBody)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, HV.Space.m)
                    .padding(.vertical, HV.Space.s)
                    .background(Palette.action, in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.content)")
        case .agent:
            agent
        }
    }

    private var tint: Color { message.failed ? Palette.danger : ChatRoomPalette(members: members).color(forHandle: message.senderHandle) }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // A failed turn is marked by a sign as well as by red, so it does not rest on colour alone.
                if message.failed {
                    Image(systemName: "exclamationmark.triangle.fill").font(.hvCaption).foregroundStyle(tint)
                } else {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Text("@\(message.senderHandle ?? "agent")").font(.hvFootnote.weight(.semibold)).foregroundStyle(tint)
                if let model = message.model, !model.isEmpty {
                    Text(model).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: HV.Space.s) {
                ChatMarkdownView(text: message.content)
                if !message.toolTurns.isEmpty {
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        ForEach(Array(message.toolTurns.enumerated()), id: \.offset) { _, turn in
                            toolLine(turn)
                        }
                    }
                    .padding(.top, HV.Space.xxs)
                }
            }
            // No tinted fill and no outline: the dot and the handle above already say who spoke, and a reply in the
            // 1:1 thread is plain text the same way. The text lines up under the handle.
            .padding(.leading, 4)
            if !message.mentions.isEmpty {
                Text("\u{2192} " + message.mentions.map { "@" + $0 }.joined(separator: ", "))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolLine(_ turn: ChatRoomToolTurn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HVIcon("wrench.and.screwdriver").font(.hvCaption)
            Text(turn.tool).font(.hvMono)
            Text(turn.summary).font(.hvCaption).foregroundStyle(turn.ok ? Palette.textSecondary : Palette.danger)
            if let slug = turn.slug {
                Button("Open") { onOpenPage(slug) }
                    .font(.hvCaption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(Palette.textSecondary)
    }
}

/// Who is up next, from the server's queue.
struct ChatTypingLine: View {
    let next: ChatRoomTurn
    let later: [ChatRoomTurn]
    let members: [ChatRoomMember]
    let isRunning: Bool

    var body: some View {
        HStack(spacing: HV.Space.xs) {
            if isRunning { ChatThinkingDots() }
            Text(line)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        var text = "@\(next.handle) is thinking..."
        if let model = members.first(where: { $0.handle == next.handle })?.backend?.defaultModel, !model.isEmpty {
            text = "@\(next.handle) (\(model)) is thinking..."
        }
        if !later.isEmpty { text += " Then " + later.map { "@" + $0.handle }.joined(separator: ", ") + "." }
        return isRunning ? text : text.replacingOccurrences(of: "is thinking...", with: "is next.")
    }
}

#if DEBUG
#Preview("Room") {
    PreviewHost(routes: ChatPreviewData.routes) {
        RoomScreen(roomID: "r1")
    }
}
#endif
