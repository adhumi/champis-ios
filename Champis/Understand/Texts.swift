import Foundation

/// Un article de Comprendre, tel que `shared/texts/index.json` le décrit (copié dans l'app par
/// `scripts/sync-texts.sh`, les mêmes mots que le site).
nonisolated struct Article: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let title: String
    let file: String
    let icon: String
    /// L'article des espèces : son texte précède les fiches servies par `GET /species`.
    let species: Bool?

    var listsSpecies: Bool { species ?? false }
}

/// Lecture des textes embarqués. Un fichier absent n'est jamais inventé : l'article est omis.
nonisolated enum Texts {
    nonisolated struct Index: Decodable {
        let version: Int
        let articles: [Article]
    }

    static func index(bundle: Bundle = .main) -> [Article] {
        guard let url = resource("index", "json", bundle), let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return [] }
        return index.articles.filter { body(of: $0, bundle: bundle) != nil }
    }

    static func body(of article: Article, bundle: Bundle = .main) -> String? {
        let parts = article.file.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = resource(parts[0], parts[1], bundle) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Les ressources d'un dossier synchronisé peuvent être à plat ou sous `Texts/`.
    private static func resource(_ name: String, _ ext: String, _ bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Texts")
            ?? bundle.url(forResource: name, withExtension: ext)
    }
}

/// Le peu de Markdown que les textes utilisent : titres, paragraphes, puces ; l'inline (gras,
/// italique, liens) est rendu par `AttributedString(markdown:)`. Fonction pure, testée.
nonisolated enum MarkdownBlocks {
    nonisolated enum Block: Hashable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Le titre de niveau 1 est celui de l'écran : on ne le répète pas dans le corps.
    static func body(_ markdown: String) -> [Block] {
        parse(markdown).filter {
            if case .heading(let level, _) = $0, level == 1 { return false }
            return true
        }
    }
}
