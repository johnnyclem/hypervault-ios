import HyperVaultKit
import SwiftUI

/// What Home says to someone with no chats: the mark, the one line, and the two things to do (start a chat; keep something),
/// then the quiet way to hand the first agent a prompt, and the first-run card that asks for an agent's key. It stands where
/// the chat list would be, under the Chats / Group chats switch, and is there only once the server has said there are no chats
/// (`ChatListModel.showsStarter`), so it never flashes under a list that is on its way.
///
/// It is not the canvas: there is no field here, and nothing to paste into. Keeping starts on the canvas, one tap away.
struct HomeStarterView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    /// The first-run card's own state. The card is asked for here, on the starter page, and not above the list of chats.
    @State private var connectCard: ConnectCardModel?
    @State private var starterCopied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: HV.Space.l) {
                    BrandMark(size: 68)
                    // (The identifiers are on the leaves: a stack's is inherited by every child that has none of its own.)
                    Text(HVCopy.landingLine)
                        .font(.hvTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.landing")

                    VStack(spacing: HV.Space.s) {
                        NavigationLink(value: ChatDestination.newConversation) {
                            Text(HVCopy.homeStartChatLabel)
                        }
                        .buttonStyle(.hvPrimary)
                        .accessibilityIdentifier("home.startChat")

                        Button {
                            app.router.push(.keep, on: .home)
                        } label: {
                            Label(HVCopy.homeKeepLabel, systemImage: HVSymbol.keep)
                        }
                        .buttonStyle(.hvGhost)
                        .accessibilityIdentifier("home.keepSomething")

                        StarterPromptButton(copied: starterCopied, identifier: "home.starter", action: copyStarter)
                    }
                }
                .padding(.horizontal, HV.Space.xl)
                .padding(.top, HV.Space.xxl)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)

                // The first-run ask for an agent's key: there only for someone with no key who has not waved it off.
                ConnectCardSlot(model: $connectCard)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { AuroraBackground() }
    }

    private func copyStarter() {
        StarterPrompt.copy(origin: env.server.baseURL)
        starterCopied = true
        Task {
            try? await Task.sleep(nanoseconds: StarterPrompt.copiedFor)
            starterCopied = false
        }
    }
}

#if DEBUG
#Preview("Home, no chats") {
    PreviewHost(routes: [.json(.get, "/api/conversations", #"{"conversations":[]}"#)]) {
        ChatRootView()
    }
}
#endif
