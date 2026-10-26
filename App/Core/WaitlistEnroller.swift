import HyperVaultKit

/// Puts someone who is signed in but not let in on the waitlist, as the web app's sign-in callback does, so the admin's
/// queue lists them. The sign-in the app does never passes through that callback. The table lets a signed-in person add
/// their own row, so this goes straight to the project's database with their token, like the invite code does.
struct WaitlistEnroller: Sendable {
    let config: SupabaseConfig
    let transport: HTTPTransport
    let tokens: TokenProvider

    /// Whether the person is on the list afterwards. Being there already counts: the table's key is the person, so a
    /// second insert is refused with a conflict, which the web ignores too.
    func enroll(_ user: AuthUser) async -> Bool {
        let client = HVClient(baseURL: config.url, transport: transport, tokens: tokens)
        var row: [String: JSONValue] = ["user_id": .string(user.id)]
        if let email = user.email { row["email"] = .string(email) }
        let call = Endpoint<NoContent>(
            .post, "/rest/v1/waitlist",
            body: .jsonValue(.object(row)),
            headers: ["apikey": config.anonKey, "Prefer": "return=minimal"]
        )
        do {
            _ = try await client.send(call)
            return true
        } catch {
            return (error as? HVError)?.status == 409
        }
    }
}
