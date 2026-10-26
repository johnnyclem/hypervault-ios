import HyperVaultKit
import SwiftUI

/// One card of the docket: the claim, why it is here, what backs it, and the record so far.
struct TruthCardView: View {
    let item: TruthDocketItem
    let replies: [TruthAgentReply]

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            tags
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                TruthClaimText(text: item.text.isEmpty ? "(no text)" : item.text, lines: nil, large: true)
                Text("\(item.author) · waiting \(item.ageText)")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            if let basis = item.basis, !basis.isEmpty { labelled("Basis", basis) }
            if let verify = item.verifyBy { labelled("Verify by", verify.sentence) }
            if !item.evidence.isEmpty { evidence }
            if !item.contestedBy.isEmpty { appeal }
            if let review = item.review { reviewNote(review) }
            if let migration = item.migration { migrationNote(migration) }
            if let derivation = item.derivation, !derivation.premises.isEmpty { trace(derivation) }
            if let approvals = item.approvals { record(approvals) }
            if !replies.isEmpty { answers }
        }
        .padding(HV.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.xl, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 6)
    }

    // MARK: Pieces

    private var tags: some View {
        TruthTagFlow {
            HVTag(text: item.kind.title, tint: item.kind == .appeal ? Palette.amber : Palette.blue)
            if item.nominated { HVTag(text: "Nominated by agents", tint: Palette.violet) }
            if item.suspect { HVTag(text: "Suspect premise", tint: Palette.amber) }
            if item.stale { HVTag(text: "Stale", tint: Palette.amber) }
            TruthStandingBadge(standing: item.standing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            Text(verbatim: text).font(.hvCallout).foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Evidence").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, entry in
                TruthEvidenceRow(evidence: entry)
            }
        }
    }

    private var appeal: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Contested by").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach(item.contestedBy) { uv in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: uv.assertion).font(.hvCallout)
                    Text("\(uv.author) · \(TruthID.short(uv.id))").font(.hvCaption).foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("You signed this TB, so you cannot refute the appeal against it. Approve the appeal to overturn the TB, strike it if it is nonsense, or leave the TB standing.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    private func reviewNote(_ review: TruthDocketReview) -> some View {
        Text(reviewSentence(review))
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewSentence(_ review: TruthDocketReview) -> String {
        var text = "The detector suspects premise \(TruthID.short(review.contests))"
        text += review.detail.isEmpty ? "." : ": \(review.detail)"
        return text + " Approving asserts this UV against it in your name; dismissing ends the review."
    }

    private func migrationNote(_ migration: TruthDocketMigration) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(migrationSource(migration))
                .font(.hvFootnote.weight(.semibold))
            if let literal = migration.literal, !literal.dead.isEmpty {
                Text(retiring(literal))
                    .font(.hvFootnote)
            }
            Text("Nothing from a page is truth until you approve it here, in your name.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    private func migrationSource(_ migration: TruthDocketMigration) -> String {
        var text = "From the page \(migration.pageSlug ?? "you pasted")"
        if let line = migration.lineID { text += ", line \(line)" }
        if let typist = migration.typedBy { text += ", typed by \(typist) (provenance, not a signer)" }
        return text + "."
    }

    private func retiring(_ literal: TruthLiteral) -> String {
        var text = "Would retire \(literal.dead)"
        if let current = literal.current { text += " in favour of \(current)" }
        return text + "."
    }

    private func approverLine(_ approval: TruthApprovalRecord) -> String {
        var inner = approval.role
        if let session = approval.agentSessionId { inner += ", \(session)" }
        return "\(approval.by) (\(inner))"
    }

    private func trace(_ root: TruthTraceNode) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(TruthTrace.rows(root)) { row in
                    TruthTraceRowView(row: row)
                    Divider().opacity(0.4)
                }
            }
            .padding(.top, HV.Space.xs)
        } label: {
            Text("Trace").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
    }

    private func record(_ approvals: TruthApprovals) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Record").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            Text(approvals.recordLine).font(.hvFootnote)
            if approvals.isReadyToPromote {
                Text("Ready to promote.").font(.hvFootnote).foregroundStyle(Palette.mint)
            } else if !approvals.missingBesidesYou.isEmpty {
                Text("Promotion still needs \(approvals.missingBesidesYou.joined(separator: ", ")).")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(Array(approvals.list.enumerated()), id: \.offset) { _, approval in
                VStack(alignment: .leading, spacing: 1) {
                    Text(approverLine(approval))
                        .font(.hvCaption.weight(.semibold))
                    if !approval.evidence.isEmpty {
                        Text(approval.evidence.map { "\($0.kind) \($0.ref)" }.joined(separator: "; "))
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let note = approval.note, !note.isEmpty {
                        Text("“\(note)”").font(.hvCaption).foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    private var answers: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("The room answered").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.violet)
            ForEach(replies) { reply in
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.handle ?? "agent").font(.hvCaption.weight(.semibold))
                    Text(verbatim: reply.content).font(.hvFootnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }
}
