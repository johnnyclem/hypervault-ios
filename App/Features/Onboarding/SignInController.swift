import AuthenticationServices
import HyperVaultKit
import SwiftUI
import UIKit

/// Runs the three ways in: Google (a web sign-in session), Sign in with Apple
/// (its native sheet) and an emailed code. Success is not handled here: the
/// auth service publishes the new session and `AppModel` moves the window on.
@MainActor
@Observable
final class SignInController {
    enum Work: Equatable { case idle, google, apple, emailSend, emailVerify }

    private(set) var work: Work = .idle
    private(set) var message: String?
    private(set) var emailSentTo: String?

    @ObservationIgnored private let auth: AuthService
    @ObservationIgnored private let announcer: SpeechAnnouncer
    @ObservationIgnored private let presenter = WebAuthPresenter()
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?

    static let callbackScheme = "hypervault"
    static let redirect = URL(string: "hypervault://auth/callback")!

    init(auth: AuthService, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared) {
        self.auth = auth
        self.announcer = announcer
    }

    var isWorking: Bool { work != .idle }

    func clearMessage() { message = nil }

    // MARK: Google

    func signInWithGoogle() async {
        guard !isWorking else { return }
        work = .google
        message = nil
        defer { work = .idle }
        do {
            let url = try await auth.authorizationURL(provider: "google", redirectTo: Self.redirect)
            let callback = try await runWebSession(url: url)
            try await auth.completeOAuth(callbackURL: callback)
            Haptics.success()
        } catch {
            fail(error)
        }
    }

    private func runWebSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.failed(error?.localizedDescription ?? "Sign-in did not finish. Try again."))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: AuthError.failed("Sign-in could not open. Try again."))
            }
        }
    }

    // MARK: Apple

    func handleApple(_ result: Result<ASAuthorization, Error>, rawNonce: String) async {
        guard !isWorking else { return }
        message = nil
        switch result {
        case .failure(let error):
            if let error = error as? ASAuthorizationError, error.code == .canceled { return }
            report("Sign in with Apple did not finish. Try again.")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else {
                report("Apple did not send what HyperVault needs. Try again.")
                return
            }
            work = .apple
            defer { work = .idle }
            do {
                try await auth.signIn(withIDToken: token, provider: "apple", nonce: rawNonce)
                Haptics.success()
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Email

    func sendEmailCode(_ email: String) async -> Bool {
        guard !isWorking else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), trimmed.contains(".") else {
            report("Enter the email you want to sign in with.")
            return false
        }
        work = .emailSend
        message = nil
        defer { work = .idle }
        do {
            try await auth.requestEmailCode(email: trimmed)
            emailSentTo = trimmed
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func verifyEmailCode(_ code: String) async {
        guard !isWorking, let email = emailSentTo else { return }
        work = .emailVerify
        message = nil
        defer { work = .idle }
        do {
            try await auth.verifyEmailCode(email: email, code: code)
            Haptics.success()
        } catch {
            fail(error)
        }
    }

    func resetEmail() {
        emailSentTo = nil
        message = nil
    }

    private func fail(_ error: Error) {
        if let error = error as? AuthError, case .cancelled = error { return }
        report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        Haptics.failure()
    }

    /// Shows a line about what went wrong and says it. The line is inserted without moving focus, and a view that
    /// appears is not announced, so a person using VoiceOver would otherwise be left waiting for a result that came.
    private func report(_ text: String) {
        message = text
        announcer.announce(text)
    }
}

/// Gives the web sign-in session a window to appear over.
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
            return window ?? ASPresentationAnchor()
        }
    }
}
