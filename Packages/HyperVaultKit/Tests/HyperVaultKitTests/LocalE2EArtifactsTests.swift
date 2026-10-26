import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Pages, their history, who can open them, passwords, groups, connections, pins, realms.

final class LocalE2EArtifactsTests: LocalE2ECase {
    private func html(_ marker: String, _ body: String = "", footer: String = "end") -> String {
        "<!doctype html>\n<html>\n<head><title>Page \(marker)</title></head>\n<body>\n<h1>\(marker)</h1>\n<p>\(body)</p>\n<hr>\n<hr>\n<hr>\n<hr>\n<hr>\n<footer>\(footer)</footer>\n</body>\n</html>\n"
    }

    private func userId(of token: String) async throws -> String {
        let caps = try await send(.capabilities, client(token))
        return try XCTUnwrap(caps.user?.id)
    }

    private func tables(_ token: String) throws -> ArtifactTables {
        guard let url = env.supabaseURL, let anon = env.anonKey else { throw XCTSkip("Set HV_E2E_SUPABASE_URL and HV_E2E_ANON_KEY.") }
        return ArtifactTables(config: SupabaseConfig(url: url, anonKey: anon), tokens: LocalStaticToken(token: token))
    }

    // MARK: Save, list, history

    func testSaveAPageListItAndReadItsFirstVersion() async throws {
        let (api, _) = member(9)
        let marker = uniqueWord()
        let other = unique("other-page")
        _ = other
        let request = ArtifactSaveRequest(
            content: html(marker, "first"), title: "Living \(marker)", tags: ["e2e", marker], makePwa: false, mutable: true,
            visibility: .private, sourcePrompt: "Make a page about \(marker)"
        )
        let (saved, raw) = try await fetch(.saveArtifact(request), api)
        XCTAssertEqual(saved.slug, raw["slug"]?.string)
        XCTAssertEqual(saved.url, raw["url"]?.string)
        XCTAssertFalse(saved.isJsx)
        XCTAssertEqual(saved.visibility, .private)
        XCTAssertTrue(saved.mutable)
        XCTAssertFalse(saved.duplicate)
        XCTAssertFalse(saved.message.isEmpty)

        // A living page is never a duplicate of another (it can be written to); a static one is.
        let fixed = ArtifactSaveRequest(content: html(marker, "static"), title: "Static \(marker)", makePwa: false, mutable: false)
        let once = try await send(.saveArtifact(fixed), api)
        let twice = try await send(.saveArtifact(fixed), api)
        XCTAssertFalse(once.duplicate)
        XCTAssertTrue(twice.duplicate, "the same static page saved twice was not recognised")
        XCTAssertEqual(twice.slug, once.slug)
        let living = try await send(.saveArtifact(request), api)
        XCTAssertFalse(living.duplicate)
        XCTAssertNotEqual(living.slug, saved.slug)

        let (list, listRaw) = try await fetch(.artifacts, api)
        XCTAssertEqual(list.items.count, rawCount(listRaw, "items"))
        let row = try XCTUnwrap(list.items.first { $0.slug == saved.slug })
        XCTAssertEqual(row.title, "Living \(marker)")
        XCTAssertEqual(row.type, "html")
        XCTAssertEqual(Set(row.tags), ["e2e", marker])
        XCTAssertEqual(row.sourcePrompt, "Make a page about \(marker)")
        XCTAssertEqual(row.visibility, .private)
        XCTAssertNotNil(row.createdAt)
        XCTAssertFalse(row.isGroup)
        XCTAssertFalse(row.isStoredFile)
        XCTAssertEqual(row.kind, .page)

        let versions = try await send(.artifactVersions(slug: saved.slug), api)
        XCTAssertEqual(versions.slug, saved.slug)
        XCTAssertTrue(versions.mutable)
        XCTAssertEqual(versions.versions.count, 1)
        let first = try XCTUnwrap(versions.versions.first)
        XCTAssertTrue(first.isHead)
        XCTAssertNil(first.parentVersionId)
        XCTAssertNotNil(first.createdAt)

        let content = try await send(.artifactContent(slug: saved.slug), api)
        XCTAssertEqual(content.title, "Living \(marker)")
        XCTAssertTrue(content.mutable)
        XCTAssertEqual(content.version?.id, first.id)
        XCTAssertEqual(content.headVersionId, first.id)
        XCTAssertNotNil(content.contentHash)
        XCTAssertTrue(content.content.contains("first"))
    }

    func testWriteDiffRevertAndTheConflictsTheAppShows() async throws {
        let (api, _) = member(9)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "alpha"), title: "History \(marker)", makePwa: false, mutable: true)), api)
        let slug = saved.slug
        let v1 = try await send(.artifactContent(slug: slug), api)
        let v1ID = try XCTUnwrap(v1.headVersionId)

        // v2 on top of v1.
        let v2 = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "beta"), message: "second", baseVersionId: v1ID)), api)
        let v2ID = try XCTUnwrap(v2.headVersionId)
        XCTAssertNotEqual(v2ID, v1ID)
        XCTAssertEqual(v2.version?.message, "second")
        XCTAssertEqual(v2.version?.parentVersionId, v1ID)
        XCTAssertFalse(v2.unchanged)

        // Writing the same content again makes no commit.
        let same = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "beta"), baseVersionId: v2ID)), api)
        XCTAssertTrue(same.unchanged)
        XCTAssertEqual(same.headVersionId, v2ID)

        let versions = try await send(.artifactVersions(slug: slug), api)
        XCTAssertEqual(versions.versions.count, 2)
        XCTAssertEqual(versions.versions.first?.id, v2ID, "newest first")
        XCTAssertTrue(versions.versions[0].isHead)
        XCTAssertFalse(versions.versions[1].isHead)
        XCTAssertEqual(versions.versions[0].message, "second")
        XCTAssertEqual(versions.versions[0].authorKind, "user")
        XCTAssertEqual(versions.versions[0].authorLine, "You")

        // An earlier version reads back as it was.
        let old = try await send(.artifactContent(slug: slug, version: v1ID), api)
        XCTAssertTrue(old.content.contains("alpha"))
        XCTAssertFalse(old.content.contains("beta"))

        // The diff is unified and counts what changed.
        let diff = try await send(.artifactDiff(slug: slug, from: v1ID), api)
        XCTAssertEqual(diff.from, v1ID)
        XCTAssertEqual(diff.to, v2ID)
        XCTAssertGreaterThan(diff.added, 0)
        XCTAssertGreaterThan(diff.removed, 0)
        XCTAssertGreaterThan(diff.hunks, 0)
        XCTAssertTrue(diff.patch.contains("-<p>alpha</p>"), diff.patch)
        XCTAssertTrue(diff.patch.contains("+<p>beta</p>"), diff.patch)
        XCTAssertFalse(diff.isEmpty)

        // A write that names no base is refused with what is there now (428), and so is one built on an older head
        // when the change cannot be replayed (409).
        let noBase = await expectFailure(428, .writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "gamma"))), api)
        let noBaseConflict = try XCTUnwrap(noBase.flatMap(ArtifactConflict.init(failure:)))
        XCTAssertEqual(noBaseConflict.reason, .preconditionRequired)
        XCTAssertEqual(noBaseConflict.headVersionId, v2ID)
        XCTAssertTrue(noBaseConflict.headContent.contains("beta"))

        let stale = await expectFailure(409, .writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "delta"), baseVersionId: v1ID)), api)
        let conflict = try XCTUnwrap(stale.flatMap(ArtifactConflict.init(failure:)), "a stale write did not come back as a conflict the Kit can read: \(String(describing: stale?.body))")
        XCTAssertEqual(conflict.reason, .rebaseConflict)
        XCTAssertEqual(conflict.headVersionId, v2ID)
        XCTAssertTrue(conflict.headContent.contains("beta"))
        XCTAssertTrue(conflict.baseContent?.contains("alpha") ?? false, "the base content is part of the owner's conflict")

        // A stale write whose change does not touch the same lines is replayed onto the head.
        let disjoint = html(marker, "alpha", footer: "retitled footer")
        let rebased = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: disjoint, message: "retitle", baseVersionId: v1ID)), api)
        XCTAssertTrue(rebased.rebased, "a change on other lines should be replayed onto the head")
        let afterRebase = try await send(.artifactContent(slug: slug), api)
        XCTAssertTrue(afterRebase.content.contains("retitled footer"))
        XCTAssertTrue(afterRebase.content.contains("beta"), "the replay lost the head's change")

        // "Keep mine": force overwrites.
        let forced = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "forced"), message: "mine", force: true)), api)
        XCTAssertTrue(forced.forced)

        // Revert makes version 1 the head again, as a new commit.
        let head = try await send(.artifactContent(slug: slug), api)
        let reverted = try await send(.revertArtifact(slug: slug, to: v1ID, base: head.headVersionId), api)
        XCTAssertNotEqual(reverted.headVersionId, head.headVersionId)
        let nowContent = try await send(.artifactContent(slug: slug), api)
        XCTAssertTrue(nowContent.content.contains("alpha"))
        XCTAssertFalse(nowContent.content.contains("forced"))
        let finalVersions = try await send(.artifactVersions(slug: slug), api)
        XCTAssertGreaterThan(finalVersions.versions.count, 4)
        XCTAssertEqual(finalVersions.versions.filter(\.isHead).count, 1)

        await expectFailure(404, .revertArtifact(slug: slug, to: "00000000-0000-4000-8000-000000000000", base: nil), api)
    }

    func testAnImmutablePageHasOneVersionAndRefusesWrites() async throws {
        let (api, _) = member(9)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker), title: "Frozen \(marker)", makePwa: false, mutable: false)), api)
        XCTAssertFalse(saved.mutable)
        let content = try await send(.artifactContent(slug: saved.slug), api)
        XCTAssertFalse(content.mutable)
        let failure = await expectFailure(409, .writeArtifact(slug: saved.slug, ArtifactWriteRequest(content: html(marker, "x"), force: true)), api)
        XCTAssertNil(failure.flatMap(ArtifactConflict.init(failure:)), "an immutable page's refusal is not a conflict the person can resolve")
    }

    // MARK: Visibility and the page route

    func testVisibilityChangesWhoCanOpenThePage() async throws {
        let (api, token) = member(10)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "visible?"), title: "Vis \(marker)", makePwa: false)), api)
        let slug = saved.slug
        let anon = client(nil)
        func anonymousPage() async throws -> HTTPResponse {
            try await anon.sendRaw(Endpoint<Data>(data: .get, "/a/\(slug)", auth: .none))
        }
        // Private: a visitor does not get the markup.
        do {
            let response = try await anonymousPage()
            XCTAssertFalse(String(decoding: response.data, as: UTF8.self).contains("visible?"), "a private page was served to a visitor")
        } catch let error as HVError {
            XCTAssertTrue([401, 403, 404].contains(error.status ?? 0), "\(error)")
        }

        // The owner, with only a bearer token, gets the page the same route serves a browser (hypervault#180).
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: LocalStaticToken(token: token), transport: LocalPacedTransport(inner: URLSessionTransport(), pacer: Self.pacer, trace: false))
        if case .html(let markup, let base) = await loader.load(slug: slug) {
            XCTAssertTrue(markup.contains("visible?"))
            XCTAssertEqual(base.path, "/a/\(slug)")
        } else {
            XCTFail("the owner's bearer token did not open their own private page")
        }
        let ownerView = try await client(token).sendRaw(Endpoint<Data>(data: .get, "/a/\(slug)"))
        XCTAssertEqual(ownerView.status, 200)
        XCTAssertTrue(String(decoding: ownerView.data, as: UTF8.self).contains("visible?"))

        // Public: anyone with the link.
        let patched = try await send(.setArtifactVisibility(slug: slug, to: .public), api)
        XCTAssertEqual(patched.artifact.slug, slug)
        XCTAssertEqual(patched.artifact.visibility, .public)
        XCTAssertFalse(patched.message.isEmpty)
        let open = try await anonymousPage()
        XCTAssertEqual(open.status, 200)
        XCTAssertTrue(String(decoding: open.data, as: UTF8.self).contains("visible?"))
        let list = try await send(.artifacts, api)
        XCTAssertEqual(list.items.first { $0.slug == slug }?.visibility, .public)

        // Password: a visitor gets the lock page, not the markup.
        let gated = try await send(.setArtifactVisibility(slug: slug, to: .password), api)
        XCTAssertEqual(gated.artifact.visibility, .password)
        let lock = try? await anonymousPage()
        if let lock {
            let text = String(decoding: lock.data, as: UTF8.self)
            XCTAssertFalse(text.contains("visible?"), "a password page was served without the password")
            XCTAssertTrue(text.contains("hv-unlock-form"), "the lock page the Kit looks for (hv-unlock-form) is not there")
        }
        if case .navigate(let address) = await loader.load(slug: slug) {
            XCTAssertEqual(address.path, "/a/\(slug)")
        } else if case .html = await loader.load(slug: slug) {
            // The owner is not asked for the password.
        } else {
            XCTFail("a password page neither opened for its owner nor offered its prompt")
        }
        _ = try await send(.setArtifactVisibility(slug: slug, to: .private), api)

        await expectFailure(404, .setArtifactVisibility(slug: "no-such-\(unique("page"))", to: .public), api)
        let (bob, _) = try second()
        await expectFailure(404, .setArtifactVisibility(slug: slug, to: .public), bob)
    }

    // MARK: Sharing

    func testSharingWithASecondPersonAndWhatEachRoleMayDo() async throws {
        let (api, token) = member(10)
        let (bob, bobToken) = try second()
        let bobCaps = try await send(.capabilities, bob)
        let bobEmail = try XCTUnwrap(bobCaps.user?.email)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "shared"), title: "Shared \(marker)", makePwa: false, mutable: true)), api)
        let slug = saved.slug
        let head = try await send(.artifactContent(slug: slug), api)

        // Before the share, Bob cannot see it.
        await expectFailure(404, .artifactContent(slug: slug), bob)
        await expectFailure(403, Endpoint<Data>(data: .get, "/a/\(slug)"), bob)

        let added = try await send(.shareArtifact(slug: slug, email: "  \(bobEmail.uppercased()) ", role: .view), api)
        XCTAssertEqual(added.role, .view)
        XCTAssertFalse(added.message.isEmpty)
        let (people, raw) = try await fetch(.artifactShares(slug: slug), api)
        XCTAssertEqual(people.people.count, rawCount(raw, "shares"))
        XCTAssertEqual(people.people.count, 1)
        let person = try XCTUnwrap(people.people.first)
        XCTAssertEqual(person.email?.lowercased(), bobEmail.lowercased())
        XCTAssertEqual(person.role, .view)
        XCTAssertTrue(people.enforced, "the stand-in runs with HYPERVAULT_SHARE_ROLES=1")
        XCTAssertEqual(Set(people.roles), Set(ArtifactShareRole.allCases))
        XCTAssertEqual(people.offeredRoles.count, 3)

        // Bob opens the page with his bearer token, and finds it in "shared with you".
        let bobPage = try await client(bobToken).sendRaw(Endpoint<Data>(data: .get, "/a/\(slug)"))
        XCTAssertEqual(bobPage.status, 200)
        XCTAssertTrue(String(decoding: bobPage.data, as: UTF8.self).contains("shared"))
        let bobUserID = try XCTUnwrap(bobCaps.user?.id)
        let shared = try await SharedWithYouReader(tables: tables(bobToken), userId: bobUserID).items()
        let item = try XCTUnwrap(shared.first { $0.slug == slug }, "the share is missing from the shared-with-you read")
        XCTAssertEqual(item.shareId, person.id)
        XCTAssertEqual(item.title, "Shared \(marker)")
        XCTAssertEqual(item.type, "html")
        XCTAssertFalse(item.isGroup)
        XCTAssertNotNil(item.createdAt)
        // Bob cannot read the owner's profile row, so the name falls away; the page is what matters.
        print("e2e shared-with-you owner as Bob sees it: \(item.owner ?? "nil")")

        // View: Bob can open it and cannot change it, share it or read its history.
        // (The server answers 404, as for a page that is not there, rather than 403.)
        await expectFailure(404, .writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "bob's"), baseVersionId: head.headVersionId)), bob)
        await expectFailure(404, .setArtifactVisibility(slug: slug, to: .public), bob)
        await expectFailure(404, .artifactShares(slug: slug), bob)
        await expectFailure(404, .deleteArtifact(slug: slug), bob)

        // Use: Bob may write the contents, not the sharing.
        let use = try await send(.shareArtifact(slug: slug, email: bobEmail, role: .use), api)
        XCTAssertEqual(use.role, .use)
        let afterUse = try await send(.artifactShares(slug: slug), api)
        XCTAssertEqual(afterUse.people.count, 1, "changing a role must not add a second row")
        XCTAssertEqual(afterUse.people.first?.role, .use)
        let bobWrite = try await send(.writeArtifact(slug: slug, ArtifactWriteRequest(content: html(marker, "bob wrote this"), message: "from Bob", baseVersionId: head.headVersionId)), bob)
        XCTAssertFalse(bobWrite.unchanged)
        await expectFailure(404, .setArtifactVisibility(slug: slug, to: .public), bob)
        let ownerSees = try await send(.artifactContent(slug: slug), api)
        XCTAssertTrue(ownerSees.content.contains("bob wrote this"))
        let versions = try await send(.artifactVersions(slug: slug), api)
        XCTAssertEqual(versions.versions.first?.message, "from Bob")

        // Edit: Bob may also set visibility.
        _ = try await send(.shareArtifact(slug: slug, email: bobEmail, role: .edit), api)
        let bobPatch = try await send(.setArtifactVisibility(slug: slug, to: .public), bob)
        XCTAssertEqual(bobPatch.artifact.visibility, .public)
        _ = try await send(.setArtifactVisibility(slug: slug, to: .private), api)

        // Ending the share takes the page away from Bob again.
        let ended = try await send(.endShare(id: person.id), api)
        XCTAssertFalse(ended.message.isEmpty)
        await expectFailure(404, .artifactContent(slug: slug), bob)
        let gone = try await SharedWithYouReader(tables: tables(bobToken), userId: bobUserID).items()
        XCTAssertNil(gone.first { $0.slug == slug })

        // Refusals: an email with no account, an invalid email, sharing with oneself, another person's page.
        await expectFailure(404, .shareArtifact(slug: slug, email: "nobody-\(unique("x"))@e2e.test", role: .view), api)
        await expectFailure(400, .shareArtifact(slug: slug, email: "not-an-email", role: .view), api)
        let selfEmail = try await send(.capabilities, client(token)).user?.email
        await expectFailure(400, .shareArtifact(slug: slug, email: try XCTUnwrap(selfEmail), role: .view), api)
        await expectFailure(404, .shareArtifact(slug: slug, email: bobEmail, role: .view), bob)
    }

    func testAPersonLeavesAShareTheyWereGiven() async throws {
        let (api, _) = member(11)
        let (bob, bobToken) = try second()
        let bobCaps = try await send(.capabilities, bob)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker), title: "Leave \(marker)", makePwa: false)), api)
        _ = try await send(.shareArtifact(slug: saved.slug, email: try XCTUnwrap(bobCaps.user?.email), role: .view), api)
        let items = try await SharedWithYouReader(tables: tables(bobToken), userId: try XCTUnwrap(bobCaps.user?.id)).items()
        let mine = try XCTUnwrap(items.first { $0.slug == saved.slug })
        _ = try await send(.endShare(id: mine.shareId), bob)
        await expectFailure(404, .artifactContent(slug: saved.slug), bob)
        let list = try await send(.artifactShares(slug: saved.slug), api)
        XCTAssertTrue(list.people.isEmpty)
    }

    // MARK: Passwords

    func testPasswordsMintListDisableAndDelete() async throws {
        let (api, _) = member(11)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker), title: "Locked \(marker)", makePwa: false)), api)
        let slug = saved.slug
        let empty = try await send(.artifactPasswords(slug: slug), api)
        XCTAssertTrue(empty.passwords.isEmpty)
        XCTAssertTrue(empty.recentVisits.isEmpty)

        let generated = try await send(.mintArtifactPassword(slug: slug, label: "for Sam", maxUses: 3), api)
        XCTAssertFalse(generated.plaintext.isEmpty, "the password is shown once, here")
        XCTAssertEqual(generated.password.label, "for Sam")
        XCTAssertEqual(generated.password.maxUses, 3)
        XCTAssertEqual(generated.password.useCount, 0)
        XCTAssertFalse(generated.password.disabled)
        XCTAssertFalse(generated.password.isUsedUp)
        let chosen = try await send(.mintArtifactPassword(slug: slug, password: "correct horse \(marker)"), api)
        XCTAssertEqual(chosen.plaintext, "correct horse \(marker)")

        let (listed, raw) = try await fetch(.artifactPasswords(slug: slug), api)
        XCTAssertEqual(listed.passwords.count, rawCount(raw, "passwords"))
        XCTAssertEqual(listed.passwords.count, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(listed.passwords), as: UTF8.self).contains(generated.plaintext), "a listed password carries its plaintext")

        let disabled = try await send(.setArtifactPasswordDisabled(slug: slug, id: generated.password.id, disabled: true), api)
        XCTAssertTrue(disabled.disabled)
        let enabled = try await send(.setArtifactPasswordDisabled(slug: slug, id: generated.password.id, disabled: false), api)
        XCTAssertFalse(enabled.disabled)

        // A visitor who knows the password gets the page.
        _ = try await send(.setArtifactVisibility(slug: slug, to: .password), api)
        let visitor = client(nil)
        let form = MultipartForm()
        _ = form
        var request = URLRequest(url: env.server.baseURL.appendingPathComponent("a/\(slug)"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("password=\(generated.plaintext.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".utf8)
        _ = visitor
        let unlock = try? await URLSessionTransport().send(request)
        if let unlock { print("e2e password unlock answered \(unlock.status)") }

        _ = try await send(.deleteArtifactPassword(slug: slug, id: generated.password.id), api)
        let after = try await send(.artifactPasswords(slug: slug), api)
        XCTAssertEqual(after.passwords.map(\.id), [chosen.password.id])
        await expectFailure(404, .deleteArtifactPassword(slug: slug, id: generated.password.id), api)
        let (bob, _) = try second()
        await expectFailure(404, .artifactPasswords(slug: slug), bob)
    }

    // MARK: Feedback, icon, connections, pins, card

    func testFeedbackIconConnectionsAndPins() async throws {
        let (api, token) = member(12)
        let userID = try await userId(of: token)
        let marker = uniqueWord()
        let a = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "a"), title: "Alpha \(marker)", makePwa: false)), api)
        let b = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker, "b"), title: "Beta \(marker)", makePwa: false)), api)

        // Feedback: up, down, cleared.
        let none = try await send(.artifactFeedback(slug: a.slug), api)
        XCTAssertNil(none.feedback)
        _ = try await send(.rateArtifact(slug: a.slug, .up), api)
        let up = try await send(.artifactFeedback(slug: a.slug), api)
        XCTAssertEqual(up.feedback, .up)
        _ = try await send(.rateArtifact(slug: a.slug, .down), api)
        let down = try await send(.artifactFeedback(slug: a.slug), api)
        XCTAssertEqual(down.feedback, .down)
        _ = try await send(.rateArtifact(slug: a.slug, nil), api)
        let cleared = try await send(.artifactFeedback(slug: a.slug), api)
        XCTAssertNil(cleared.feedback)

        // Icon.
        let icon = try await send(.setArtifactIcon(slug: a.slug, glyph: "🔥"), api)
        XCTAssertEqual(icon.artifact.icon, "🔥")
        let listed = try await send(.artifacts, api)
        XCTAssertEqual(listed.items.first { $0.slug == a.slug }?.icon, "🔥")
        let cleared2 = try await send(.setArtifactIcon(slug: a.slug, glyph: nil), api)
        XCTAssertNil(cleared2.artifact.icon)

        // Connections: by slug, then read as edges, then removed.
        let connected = try await send(.connectArtifact(source: a.slug, target: b.slug), api)
        XCTAssertFalse(connected.message.isEmpty)
        let (edges, raw) = try await fetch(.artifactEdges, api)
        XCTAssertEqual(edges.connections.count, rawCount(raw, "connections"))
        XCTAssertEqual(edges.memoryArtifactLinks.count, rawCount(raw, "memory_artifact_links"))
        // Edges name pages by row id; the card is what turns a slug into one.
        let aID = try await send(.card(slug: a.slug), api).id
        let bID = try await send(.card(slug: b.slug), api).id
        let pair = Set([aID, bID])
        let edge = try XCTUnwrap(edges.connections.first { Set([$0.aId, $0.bId]) == pair }, "the connection is not in the graph")
        XCTAssertEqual(edge.kind, "manual")
        XCTAssertFalse(edge.isAuto)
        XCTAssertNotNil(edge.createdAt)
        let again = try await send(.connectArtifact(source: b.slug, target: a.slug), api)
        XCTAssertFalse(again.message.isEmpty)
        let edgesAgain = try await send(.artifactEdges, api)
        XCTAssertEqual(edgesAgain.connections.filter { Set([$0.aId, $0.bId]) == pair }.count, 1, "connecting the same pair twice made two edges")
        _ = try await send(.disconnect(edge: edge.id), api)
        let edgesAfter = try await send(.artifactEdges, api)
        XCTAssertNil(edgesAfter.connections.first { $0.id == edge.id })
        await expectFailure(404, .connectArtifact(source: a.slug, target: "no-such-\(unique("page"))"), api)

        // Pins are written whole and read back from the profile.
        let reader = SidebarPinsReader(tables: try tables(token), userId: userID)
        _ = try await send(.replaceSidebarPins([.artifact(b.slug), .artifact(a.slug)]), api)
        var pins = try await reader.pins()
        XCTAssertEqual(pins.artifactSlugs, [b.slug, a.slug], "pins come back in the order they were written")
        let moved = pins.movingArtifact(from: 1, to: 0)
        _ = try await send(.replaceSidebarPins(moved.pins), api)
        pins = try await reader.pins()
        XCTAssertEqual(pins.artifactSlugs, [a.slug, b.slug])
        _ = try await send(.replaceSidebarPins([]), api)
        pins = try await reader.pins()
        XCTAssertTrue(pins.pins.isEmpty)

        // The card on the canvas, and opening a thing makes it the most recent.
        let card = try await send(.card(slug: a.slug), api)
        XCTAssertEqual(card.name, "Alpha \(marker)")
        XCTAssertEqual(card.kind, .page)
        XCTAssertEqual(card.slug, a.slug)
        let byID = try await send(.card(kind: .page, id: card.id), api)
        XCTAssertEqual(byID.id, card.id)
        let stamp = try await send(.markOpened(kind: .page, id: card.id), api)
        XCTAssertEqual(stamp.persisted, true)
        let yours = try await send(.yours(), api)
        XCTAssertNotNil(yours.results.first { $0.slug == a.slug }?.lastOpenedAt, "opening a page did not stamp it")
        XCTAssertEqual(yours.recent.first?.slug, a.slug, "the page opened last is not first in Recent")
    }

    // MARK: Delete

    func testDeletingAPageRemovesItEverywhere() async throws {
        let (api, _) = member(12)
        let marker = uniqueWord()
        let saved = try await send(.saveArtifact(ArtifactSaveRequest(content: html(marker), title: "Doomed \(marker)", makePwa: false)), api)
        let deleted = try await send(.deleteArtifact(slug: saved.slug), api)
        XCTAssertEqual(deleted.deleted.slug, saved.slug)
        XCTAssertEqual(deleted.deleted.title, "Doomed \(marker)")
        XCTAssertFalse(deleted.message.isEmpty)
        await expectFailure(404, .artifactContent(slug: saved.slug), api)
        await expectFailure(404, .deleteArtifact(slug: saved.slug), api)
        let list = try await send(.artifacts, api)
        XCTAssertNil(list.items.first { $0.slug == saved.slug })
        let yours = try await send(.yours(query: marker), api)
        XCTAssertTrue(yours.results.isEmpty)
        let (bob, _) = try second()
        let theirs = try await send(.saveArtifact(ArtifactSaveRequest(content: html(uniqueWord()), title: "Not yours", makePwa: false)), api)
        await expectFailure(404, .deleteArtifact(slug: theirs.slug), bob)
    }

    // MARK: Groups

    func testGroupsCreateEditFilesAndDelete() async throws {
        let (api, token) = member(13)
        let marker = uniqueWord()
        let files = [
            ArtifactGroupFile(path: "index.html", content: "<!doctype html><html><head><link rel=stylesheet href=style.css></head><body><h1>\(marker)</h1></body></html>"),
            ArtifactGroupFile(path: "style.css", content: "h1 { color: red }"),
        ]
        let (created, raw) = try await fetch(.createArtifactGroup(title: "Group \(marker)", files: files, tags: ["e2e"], visibility: .private), api)
        XCTAssertEqual(created.slug, raw["slug"]?.string)
        XCTAssertEqual(Set(created.files), ["index.html", "style.css"])
        XCTAssertEqual(created.visibility, .private)
        XCTAssertTrue(created.url.contains("/g/\(created.slug)"), created.url)

        let (groups, groupsRaw) = try await fetch(.artifactGroups, api)
        XCTAssertEqual(groups.items.count, rawCount(groupsRaw, "items"))
        let row = try XCTUnwrap(groups.items.first { $0.slug == created.slug })
        XCTAssertEqual(row.title, "Group \(marker)")
        XCTAssertEqual(row.tags, ["e2e"])
        XCTAssertNotNil(row.createdAt)

        let detail = try await send(.artifactGroup(slug: created.slug), api)
        XCTAssertEqual(detail.files.count, 2)
        XCTAssertEqual(detail.files.first { $0.path == "style.css" }?.content, "h1 { color: red }")
        XCTAssertEqual(detail.files.first { $0.path == "style.css" }?.sizeBytes, "h1 { color: red }".utf8.count)
        XCTAssertNotNil(detail.createdAt)

        // Add, overwrite (a nested path keeps its slashes), remove.
        _ = try await send(.addGroupFile(slug: created.slug, path: "js/app.js", content: "console.log(1)"), api)
        await expectFailure(409, .addGroupFile(slug: created.slug, path: "js/app.js", content: "again"), api)
        _ = try await send(.writeGroupFile(slug: created.slug, path: "js/app.js", content: "console.log(2)"), api)
        var after = try await send(.artifactGroup(slug: created.slug), api)
        XCTAssertEqual(after.files.first { $0.path == "js/app.js" }?.content, "console.log(2)")
        _ = try await send(.deleteGroupFile(slug: created.slug, path: "js/app.js"), api)
        after = try await send(.artifactGroup(slug: created.slug), api)
        XCTAssertNil(after.files.first { $0.path == "js/app.js" })
        await expectFailure(400, .deleteGroupFile(slug: created.slug, path: "index.html"), api)

        // Title, tags and visibility.
        _ = try await send(.updateArtifactGroup(slug: created.slug, title: "Renamed \(marker)", tags: ["e2e", "two"], visibility: .public), api)
        let renamed = try await send(.artifactGroup(slug: created.slug), api)
        XCTAssertEqual(renamed.title, "Renamed \(marker)")
        XCTAssertEqual(Set(renamed.tags), ["e2e", "two"])
        XCTAssertEqual(renamed.visibility, .public)

        // A group shows in Yours as a group, and the page loader reads it whole.
        let yours = try await send(.yours(query: marker), api)
        let item = try XCTUnwrap(yours.results.first { $0.slug == created.slug })
        XCTAssertEqual(item.kind, .group)
        XCTAssertEqual(item.href, "/g/\(created.slug)")
        _ = try await send(.updateArtifactGroup(slug: created.slug, visibility: .private), api)
        let loader = ArtifactPageLoader(baseURL: env.server.baseURL, tokens: LocalStaticToken(token: token), transport: LocalPacedTransport(inner: URLSessionTransport(), pacer: Self.pacer, trace: false))
        if case .html(let document, let base) = await loader.load(slug: created.slug, isGroup: true) {
            XCTAssertTrue(document.contains(marker))
            XCTAssertEqual(base.path, "/g/\(created.slug)")
        } else {
            XCTFail("the owner's group did not load as a document")
        }
        await expectFailure(400, .createArtifactGroup(title: "No index", files: [ArtifactGroupFile(path: "a.txt", content: "x")], tags: [], visibility: .private), api)
        let (bob, _) = try second()
        await expectFailure(404, .artifactGroup(slug: created.slug), bob)

        let deleted = try await send(.deleteArtifactGroup(slug: created.slug), api)
        XCTAssertFalse(deleted.message.isEmpty)
        await expectFailure(404, .artifactGroup(slug: created.slug), api)
    }
}
