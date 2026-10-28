import HyperVaultKit
import SwiftUI

/// Tells the person about a background job (a page repair, say) that finished while nobody was watching: the web's
/// `JobNotifications`. While the Home canvas or the Library is showing and the app is in front, it asks the server for the
/// finished jobs nobody has acknowledged, on appearing and then every 20 seconds, and keeps the newest in a banner until
/// the person dismisses it. Dismissing is what tells the server, so a job interrupts once; a job that changed something
/// also makes the Library read again (`changes`).
///
/// There is one of these to a signed-in environment, so two screens showing at once share the one question, the one
/// banner and the one acknowledgement. An ask that fails says nothing, as on the web: the next one will do.
@MainActor
@Observable
final class JobNotices {
    /// The notice the banner shows, or nil when there is nothing to say.
    private(set) var current: BackgroundJobNotice?
    /// How many more are waiting behind it.
    private(set) var waiting = 0
    /// Counts the dismissed notices whose job changed something. A screen that lists what a job may have changed reads
    /// again when it moves.
    private(set) var changes = 0

    /// How far telling the server that a dismissed job was seen has got.
    private enum Telling { case owed, sending, done }

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private let announcer: SpeechAnnouncer
    /// The screens that are showing and want the notices, each by a token of its own, so one that reports twice counts once.
    @ObservationIgnored private var watchers: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var queue: [BackgroundJobNotice] = []
    /// Every job dismissed in this run of the app. None of them is shown again, whether or not the server heard.
    @ObservationIgnored private var dismissed: [String: Telling] = [:]
    @ObservationIgnored private var announced: String?

    /// `interval` is seconds between asks: the web's 20, unless a test wants it shorter.
    init(client: HVClient, interval: TimeInterval = 20, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared) {
        self.client = client
        self.interval = interval
        self.announcer = announcer
    }

    // MARK: Asking

    /// A screen says whether it is showing now, with the app in front, where the notices belong. The first to say yes
    /// starts the asking and the last to say no stops it; saying the same thing twice changes nothing.
    func setWatching(_ screen: UUID, _ watching: Bool) {
        if watching { watchers.insert(screen) } else { watchers.remove(screen) }
        if watchers.isEmpty {
            loop?.cancel()
            loop = nil
        } else if loop == nil {
            startAsking()
        }
    }

    /// Asks now and then every `interval` seconds, until the last screen has gone. The loop holds the model only while it
    /// asks, so it ends by itself if the model is gone first.
    private func startAsking() {
        let pause = UInt64(interval * 1_000_000_000)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if await self?.poll() == nil { return }
                try? await Task.sleep(nanoseconds: pause)
            }
        }
    }

    /// Asks for the finished jobs nobody has acknowledged and shows the newest. An answer that does not come, or that
    /// comes after the last screen has gone, says nothing.
    func poll() async {
        guard let list = try? await client.send(.backgroundJobs), !Task.isCancelled else { return }
        // A job the person dismissed that the server still lists was not told about, or not yet: tell it again.
        for job in list.jobs where dismissed[job.id] == .owed { acknowledge(job.id) }
        queue = BackgroundJobNotice.queue(from: list.jobs, skipping: Set(dismissed.keys), holding: current?.id)
        show()
    }

    // MARK: Saying

    /// Puts the first notice in the banner, and says it aloud the first time it comes up: a view that appears is not
    /// announced, so VoiceOver would otherwise never hear of it.
    private func show() {
        let next = queue.first
        if next != current { current = next }
        let more = max(queue.count - 1, 0)
        if more != waiting { waiting = more }
        guard let next, next.id != announced else { return }
        announced = next.id
        announcer.announce(next.spoken)
    }

    /// The person has read the notice `id` and closed it. The server is told, so that it says nothing more about the job,
    /// and the next notice takes its place. A tap on a notice that has already gone changes nothing.
    func dismiss(_ id: String) {
        guard let notice = current, notice.id == id else { return }
        dismissed[id] = .owed
        queue.removeAll { $0.id == id }
        if notice.changedSomething { changes += 1 }
        show()
        acknowledge(id)
    }

    private func acknowledge(_ id: String) {
        guard dismissed[id] == .owed else { return }
        dismissed[id] = .sending
        let client = self.client
        Task { [weak self] in
            let told = (try? await client.send(.acknowledgeBackgroundJob(id: id))) != nil
            let state: Telling = told ? .done : .owed
            self?.dismissed[id] = state
        }
    }
}

extension BackgroundJobNotice {
    /// What VoiceOver says, and the banner's label: the words, and that the job failed, which the icon alone shows to the eye.
    var spoken: String {
        succeeded ? "\(title). \(message)" : "Error. \(title). \(message)"
    }
}
