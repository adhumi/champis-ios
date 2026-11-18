import Foundation
import SwiftUI

/// Une entrée de la section Guide de Mes coins (19 nov. 2026 : l'onglet Guide est retiré) : un
/// article embarqué, présenté par un titre et une phrase propres à l'app. L'icône reste celle de
/// l'article dans `shared/texts/index.json`.
nonisolated struct GuideCard: Identifiable, Hashable, Sendable {
    let article: Article
    let title: String
    let subtitle: String

    var id: String { article.id }
}

/// Les quatre entrées du Guide montrées sous les coins, dans cet ordre. Les autres articles
/// (confidentialité, mentions légales) se lisent depuis les réglages. Un article absent des textes
/// embarqués n'a pas d'entrée : rien n'est inventé.
nonisolated enum GuideCards {
    static let texts: [(id: String, title: String, subtitle: String)] = [
        (
            "comment-ca-marche", "Comment ça marche ?",
            "L'app ne voit évidemment pas les champignons. Elle estime chaque jour pour chaque coin de forêt les chances qu'une espèce y pousse."
        ),
        (
            "donnees-et-sources", "Source des données",
            "Toutes les données de Champis sont issues de sources publiques et sous licence ouverte. Aucune n'est achetée et rien n'est deviné."
        ),
        (
            "especes", "Les champis de Champis",
            "Découvrez les espèces de champignons que vous retrouverez dans l'app."
        ),
        (
            "cueillir-sans-nuire", "Cueillir sans nuire",
            "Champis indique un potentiel de pousse calculé selon un modèle mathématique, en aucun cas une autorisation."
        ),
    ]

    static func cards(from articles: [Article]) -> [GuideCard] {
        texts.compactMap { text in
            guard let article = articles.first(where: { $0.id == text.id }) else { return nil }
            return GuideCard(article: article, title: text.title, subtitle: text.subtitle)
        }
    }
}

/// Une ligne du Guide : l'icône de l'article, son titre et sa phrase.
struct GuideRow: View {
    let card: GuideCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.article.icon)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title).font(.headline)
                Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
