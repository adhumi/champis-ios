import SwiftUI

/// Un `Problem` à l'écran (étape B4) : la phrase en clair, « Réessayer » quand l'action a un sens,
/// et le détail technique derrière « Détails ». Boutons sans bordure : dans une ligne de liste,
/// chacun reste touchable seul.
struct ProblemView: View {
    let problem: Problem
    var retry: (() -> Void)?
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(problem.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
            HStack(spacing: 16) {
                if problem.retryable, let retry {
                    Button("Réessayer", action: retry)
                        .fontWeight(.semibold)
                }
                if problem.detail != nil {
                    Button(showsDetail ? "Masquer le détail" : "Détails") {
                        showsDetail.toggle()
                    }
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            if showsDetail, let detail = problem.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: problem) { showsDetail = false }
    }
}
