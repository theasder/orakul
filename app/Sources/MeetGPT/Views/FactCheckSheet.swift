import SwiftUI

/// Color-coded fact-check results: each claim from the transcript, verified
/// against the call's user-provided context. Green = supported, yellow = needs
/// an external source, red = contradicted, gray = not checkable.
struct FactCheckSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.factCheck)
    }

    @ViewBuilder private var trackedBody: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Label("Проверка фактов", systemImage: "checkmark.seal")
                    .font(Typo.title).foregroundStyle(Theme.ink)
                if state.factChecking { BreathingDots(tint: Theme.accent) }
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            Text("Claims from the transcript, checked only against the context you added for this call.")
                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)

            // Item 11: the explicit, per-request web opt-in. This button is the
            // ONLY path that sets searchWeb — the background loop never does —
            // so nothing reaches a search engine without this exact click.
            HStack(spacing: Space.s) {
                Button {
                    state.runFactCheck(searchWeb: true)
                } label: {
                    Label("Проверить в вебе", systemImage: "globe")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(state.factChecking)
                .help("Re-checks unsettled claims against web search — sends their queries to a search provider and uses search credits.")
                if let search = state.factCheckSearch {
                    if search.ran == true {
                        Text("Searched \(search.sources?.count ?? 0) web sources")
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    } else if let reason = search.reason, !reason.isEmpty {
                        Text(reason)
                            .font(Typo.caption).foregroundStyle(Theme.amber)
                            .lineLimit(2)
                            .help(reason)
                    }
                }
                Spacer()
            }

            if state.factChecking && state.factClaims.isEmpty {
                centered {
                    ProgressView()
                    Text("Сверяю с вашим контекстом…")
                        .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                }
            } else if let error = state.factCheckError, state.factClaims.isEmpty {
                centered {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26)).foregroundStyle(Theme.danger)
                    Text("Проверка фактов не удалась")
                        .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(error)
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .truncationMode(.tail)
                        .help(error)
                }
            } else if state.factClaims.isEmpty {
                centered {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 26)).foregroundStyle(Theme.inkTertiary)
                    Text("Проверяемых утверждений пока нет.")
                        .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(state.factClaims) { FactClaimRow(claim: $0) }
                        // Every page retrieved, not only the cited ones: "we
                        // read these five and none supported it" is a different
                        // answer from an empty list.
                        if let sources = state.factCheckSearch?.sources,
                           state.factCheckSearch?.ran == true, !sources.isEmpty {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("ИСТОЧНИКИ В ВЕБЕ")
                                    .font(Typo.label).tracking(0.5)
                                    .foregroundStyle(Theme.inkTertiary)
                                ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { _, source in
                                    if let raw = source.url, let url = URL(string: raw) {
                                        Link(destination: url) {
                                            Label(source.title?.isEmpty == false ? source.title! : (url.host() ?? raw),
                                                  systemImage: "link")
                                                .font(Typo.caption)
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(Theme.inkSecondary)
                                        .help(raw)
                                    }
                                }
                            }
                            .padding(.top, Space.s)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(Space.xl)
        .frame(width: 460, height: 560)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Space.m) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FactClaimRow: View {
    let claim: FactClaim

    private var tint: Color {
        switch claim.status {
        case .verified:     return Theme.speakerYou    // green
        case .needsContext: return Theme.amber         // yellow
        case .contradicted: return Theme.danger        // red
        case .inconsistent: return Theme.danger        // red — the call disagrees with itself
        case .unverifiable: return Theme.inkTertiary   // gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 5)

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(claim.status.label.uppercased())
                        .font(Typo.label).tracking(0.5).foregroundStyle(tint)
                    if claim.isWebChecked {
                        // Labelled apart, deliberately: "verified against a web
                        // page" is a weaker epistemic state than "verified
                        // against a document you attached", and the reader must
                        // be able to tell which one they are trusting.
                        Label("Веб", systemImage: "globe")
                            .font(Typo.label)
                            .foregroundStyle(Theme.inkTertiary)
                            .help("Checked against a retrieved web page, not your attached context")
                    }
                    if let confidence = claim.confidence {
                        Text(confidence.label)
                            .font(Typo.label)
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, Space.s).padding(.vertical, 1)
                            .background(Theme.canvas, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .help("How solid this verdict is, given the evidence")
                    }
                    Spacer()
                }
                Text(claim.text)
                    .font(Typo.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !claim.explanation.isEmpty {
                    Text(claim.explanation)
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = claim.source, !source.isEmpty {
                    Text("“\(source)”")
                        .font(Typo.caption.italic()).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Space.s)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.4)).frame(width: 2)
                        }
                }
                if claim.isWebChecked, let raw = claim.sourceUrl, let url = URL(string: raw) {
                    // The traceable page behind a web verdict. Without this the
                    // reader cannot disagree with the verdict, which makes it
                    // worth less than no verdict.
                    Link(destination: url) {
                        Label(claim.sourceTitle ?? url.host() ?? raw, systemImage: "link")
                            .font(Typo.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .help(raw)
                }
                if let question = claim.counterQuestion, !question.isEmpty {
                    Label(question, systemImage: "questionmark.bubble")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Ask this to confirm or falsify the claim")
                }
            }
        }
        .padding(Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
