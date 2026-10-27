import HyperVaultKit
import SwiftUI

/// Compiling, from "working" to "done". The server reports no progress while
/// it works (it reads every server, then builds a search index, which can take
/// a few minutes), so this shows what is true: what it is doing, how long it
/// has been, and that it is safe to stop waiting.
struct ToolsCompileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ToolsModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HV.Space.l) {
                    switch model.compile {
                    case .idle:
                        EmptyView()
                    case .running(let since, let servers, let tools):
                        running(since: since, servers: servers, tools: tools)
                    case .finished(let result):
                        finished(result)
                    case .recovered(let toolkit):
                        recovered(toolkit)
                    case .failed(let message):
                        failed(message, symbol: "exclamationmark.circle")
                    case .lostConnection(let message):
                        failed(message, symbol: "wifi.exclamationmark")
                    case .nothingToCompile:
                        nothingToCompile
                    case .stopped:
                        stopped
                    }
                }
                // The same side margin as the other Tools sheets, so the edges stay put from one to the next.
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationTitle("Compile tools")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.compile.isRunning)
        .onChange(of: model.compile) { _, state in
            if state == .idle { dismiss() }
        }
    }

    // MARK: Running

    private func running(since: Date, servers: Int, tools: Int) -> some View {
        VStack(spacing: HV.Space.l) {
            ProgressView().controlSize(.large).padding(.top, HV.Space.xl)
            VStack(spacing: HV.Space.xs) {
                Text("Building your toolkit").font(.hvTitle)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(since)))
                        .font(.system(.title3, design: .monospaced, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityLabel("Elapsed \(Int(context.date.timeIntervalSince(since))) seconds")
                }
            }
            Text("Reading \(tools) tool\(tools == 1 ? "" : "s") from \(servers) server\(servers == 1 ? "" : "s"), then building the index your chats search to pick the right one. It usually takes under a minute, and can take a few minutes the first time.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Text("You can put your phone away. If the connection drops, HyperVault checks whether the build finished.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
            Button("Stop waiting") { model.stopWaiting() }
                .buttonStyle(.hvSecondary)
                .padding(.top, HV.Space.s)
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Done

    private func finished(_ result: McpCompileResult) -> some View {
        VStack(spacing: HV.Space.l) {
            doneHeader(title: "Your toolkit is ready", subtitle: "New chats can use these tools now.")
            statsCard(result.stats, label: result.embedderLabel)

            if result.isLexical {
                note(
                    symbol: "exclamationmark.triangle.fill", tint: Palette.warning,
                    text: "Matching by wording only. A request has to sound like the tool's name, or HyperVault will ask which tool you mean."
                        + (result.embedderDegradeReason.map { " The model that reads meaning did not load: \($0)." } ?? "")
                )
            }
            if !result.skippedServers.isEmpty {
                note(
                    symbol: "exclamationmark.circle.fill", tint: Palette.warning,
                    text: "Not reached this time: " + result.skippedServers.map { "\($0.name) (\($0.error))" }.joined(separator: "; ") + "."
                )
            }
            if result.stats.collisionCount > 0 {
                collisions(result)
            }
            Button("Done") { model.dismissCompile(); dismiss() }.buttonStyle(.hvPrimary)
        }
    }

    private func recovered(_ toolkit: McpToolkit) -> some View {
        VStack(spacing: HV.Space.l) {
            doneHeader(title: "Your toolkit is ready", subtitle: "The connection dropped while it was building, and it finished on the server.")
            statsCard(toolkit.stats, label: toolkit.embedderLabel)
            Button("Done") { model.dismissCompile(); dismiss() }.buttonStyle(.hvPrimary)
        }
    }

    private func doneHeader(title: String, subtitle: String) -> some View {
        VStack(spacing: HV.Space.s) {
            ZStack {
                Circle().fill(Palette.mint.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: "checkmark").font(.system(size: 34, weight: .semibold)).foregroundStyle(Palette.mint)
            }
            .padding(.top, HV.Space.l)
            .accessibilityHidden(true)
            Text(title).font(.hvTitle)
            Text(subtitle).font(.hvCallout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
        }
    }

    private func statsCard(_ stats: McpToolkitStats, label: String) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            // Three across when they fit; stacked at the larger text sizes, where "Ways to ask" would not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { statColumns(stats) }
                VStack(alignment: .leading, spacing: HV.Space.s) { statColumns(stats) }
            }
            Text("Ways to ask are the different things a chat can say to reach a tool. Look-alikes are pairs of tools that are easy to mix up.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
            if !label.isEmpty {
                Text("Matching: \(label)")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .hvCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statColumns(_ stats: McpToolkitStats) -> some View {
        stat(stats.toolCount, "Tools", "Every tool you left switched on.")
        stat(stats.uniqueSelectorCount, "Ways to ask", "Distinct things a chat can say to reach a tool.")
        stat(stats.collisionCount, "Look-alikes", "Pairs of tools that are easy to mix up.")
    }

    private func stat(_ value: Int, _ title: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(.title, weight: .bold))
            Text(title).font(.hvFootnote).foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title). \(help)")
    }

    private func note(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hvCard()
    }

    private func collisions(_ result: McpCompileResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                ForEach(Array(result.collisions.prefix(8).enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(pair.selectorA) and \(pair.selectorB)").font(.hvMono)
                        if !pair.hint.isEmpty { Text(pair.hint).font(.hvCaption).foregroundStyle(Palette.textSecondary) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HV.Space.xs)
        } label: {
            Text("Which tools look alike").font(.hvCallout)
        }
        .hvCard()
    }

    // MARK: Trouble

    private func failed(_ message: String, symbol: String) -> some View {
        VStack(spacing: HV.Space.l) {
            HVErrorState(message: message, symbol: symbol)
            VStack(spacing: HV.Space.xs) {
                Button("Try again") { model.startCompile() }.buttonStyle(.hvPrimary)
                Button("Close") { model.dismissCompile(); dismiss() }.buttonStyle(.hvGhost)
            }
        }
    }

    /// Every tool is off. Trying again cannot change that, so the way out is back to the list.
    private var nothingToCompile: some View {
        VStack(spacing: HV.Space.l) {
            HVEmptyState(
                symbol: "slider.horizontal.3",
                title: "Nothing to compile",
                message: "Every tool is switched off, so there is nothing for your chats to use. Switch on at least one, then compile again."
            )
            Button("Choose tools") { model.dismissCompile(); dismiss() }.buttonStyle(.hvPrimary)
        }
    }

    private var stopped: some View {
        VStack(spacing: HV.Space.l) {
            HVEmptyState(
                symbol: "hourglass",
                title: "Stopped waiting",
                message: "HyperVault may still finish building on the server. Check in a minute, or pull to refresh the Tools screen."
            )
            VStack(spacing: HV.Space.xs) {
                Button("Check now") { Task { await model.checkToolkitNow() } }.buttonStyle(.hvPrimary)
                Button("Close") { model.dismissCompile(); dismiss() }.buttonStyle(.hvGhost)
            }
        }
    }
}

#if DEBUG
#Preview("Compile") {
    PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
        ToolsModelHost(prepare: { $0.startCompile() }) { model, _ in ToolsCompileSheet(model: model) }
    }
}
#endif
