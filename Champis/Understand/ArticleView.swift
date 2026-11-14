import ChampisScoring
import SwiftUI

/// Un article de Comprendre : les blocs Markdown du texte embarqué, et pour « Les espèces » la
/// liste des fiches servies par `GET /species` sous le texte.
struct ArticleView: View {
    let article: Article
    let model: MapModel

    var body: some View {
        List {
            if let markdown = Texts.body(of: article) {
                Section {
                    MarkdownView(blocks: MarkdownBlocks.body(markdown))
                }
            }
            if article.listsSpecies {
                speciesSection
            }
        }
        .listStyle(.plain)
        .navigationTitle(article.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder
    private var speciesSection: some View {
        let groups = Dictionary(grouping: model.catalog?.species.values.sorted { ($0.names?.fr ?? $0.id) < ($1.names?.fr ?? $1.id) } ?? []) {
            $0.group?.fr ?? "Autres"
        }
        ForEach(groups.keys.sorted(), id: \.self) { group in
            Section(group) {
                ForEach(groups[group] ?? [], id: \.id) { species in
                    NavigationLink {
                        SpeciesView(species: species, photoURL: model.api.photoURL(species: species.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(species.names?.fr ?? species.id)
                            Text(species.names?.la ?? "").font(.subheadline).italic().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if model.catalog == nil {
            Text("Les fiches arrivent avec le catalogue des espèces, au premier démarrage connecté.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Rendu des blocs Markdown : titres, paragraphes, puces, inline par `AttributedString`.
struct MarkdownView: View {
    let blocks: [MarkdownBlocks.Block]

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(let level, let text):
                Text(text)
                    .font(level <= 2 ? .title3 : .headline)
                    .fontWeight(.semibold)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph(let text):
                Text(Self.inline(text))
            case .bullet(let text):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(Self.inline(text))
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Fiche d'une espèce (lot 4) : photo libre créditée, où et quand en mots, les confusions
/// dangereuses, la consigne du pharmacien. Aucune aide à l'identification, aucun chiffre.
/// La photo est la copie du référentiel servie par le site (`ChampisAPI.photoURL`), jamais
/// l'adresse Wikimedia de `about.photo.url` : ouvrir une fiche n'envoie rien à un tiers
/// (13 nov. 2026). Le crédit et son lien vers la page Commons viennent toujours de `about.photo`.
struct SpeciesView: View {
    let species: Species
    /// Adresse de la photo sur le site ; `nil` : « Photo à venir ».
    let photoURL: URL?

    var body: some View {
        List {
            if let about = species.about {
                Section {
                    photo(about.photo)
                    Text(about.summary)
                }
                Section("Où") { Text(about.habitat) }
                Section("Quand") { Text(about.season) }
                Section {
                    ForEach(about.confusions, id: \.self) { confusion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(confusion.name).font(.headline)
                            Text(confusion.latin).italic().foregroundStyle(.secondary)
                            Text(confusion.risk)
                            Text(confusion.tell).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Ne pas confondre avec")
                } footer: {
                    Text("Ces fiches n'aident pas à identifier un champignon. Faites contrôler votre récolte par un pharmacien ou une association mycologique.")
                }
                if !about.references.isEmpty {
                    Section("Sources") {
                        DisclosureGroup("Références") {
                            ForEach(about.references.keys.sorted(), id: \.self) { key in
                                Text(about.references[key] ?? key).font(.footnote)
                            }
                        }
                    }
                }
            } else {
                Text("Fiche à venir.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(species.names?.fr ?? species.id)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func photo(_ photo: Species.About.Photo?) -> some View {
        if let photo, let url = photoURL {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder("Photo indisponible hors ligne")
                    default:
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Photo de \(species.names?.fr ?? species.id)")
                // lien venu des données du serveur : https seulement
                if let page = ChampisAPI.httpsURL(photo.page) {
                    Link("\(photo.author) · \(photo.license) · Wikimedia Commons", destination: page)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(photo.author) · \(photo.license)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden)
        } else {
            placeholder("Photo à venir")
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack {
            Spacer()
            Label(text, systemImage: "photo").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(minHeight: 120)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
