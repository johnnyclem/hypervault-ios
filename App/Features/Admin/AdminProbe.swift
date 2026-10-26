import HyperVaultKit
import SwiftUI

extension AppEnvironment {
    /// Finds out whether this account is an admin and sets `isAdmin`. The You
    /// tab calls it when it appears; it must be cheap and never show an error.
    ///
    /// There is no "am I an admin" read, and no GET route under `app/api/admin`,
    /// so this sends a PATCH with an empty body to an invite code that does not
    /// exist. Every admin route starts with the admin check; a person who passes
    /// it reaches the body check, which refuses the empty body (400) before the
    /// database is touched, and anyone else is turned away first (403). See
    /// `AdminProbe`. The answer is remembered for hours, and an unclear one
    /// (signed out of the web session, offline) is left alone for ten minutes.
    func probeAdmin() async {
        let record = await cache.entry(AdminProbeRecord.self, key: "admin.probe", namespace: user.id)?.value
        if let record, record.isFresh() {
            if let known = record.isAdmin { isAdmin = known }
            return
        }

        let verdict: AdminProbe.Verdict
        do {
            _ = try await client.send(.adminProbe)
            verdict = .admin
        } catch let error as HVError {
            // Offline or cancelled tells nothing: try again next time.
            if error.isOffline { return }
            if case .cancelled = error { return }
            verdict = AdminProbe.verdict(status: error.status)
        } catch {
            return
        }

        await cache.store(AdminProbeRecord(verdict), key: "admin.probe", namespace: user.id)
        switch verdict {
        case .admin: isAdmin = true
        case .notAdmin: isAdmin = false
        case .unknown: break
        }
    }
}
