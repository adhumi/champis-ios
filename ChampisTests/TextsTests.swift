import ChampisScoring
import Foundation
import Testing
@testable import Champis

struct TextsTests {
    @Test("Markdown des textes : titres, paragraphes repliés, puces ; le titre 1 n'est pas répété")
    func markdown() {
        let md = """
        # Titre

        Première ligne
        suite de la même phrase.

        ## Section

        - une puce
        - **deux** puces

        Fin.
        """
        let blocks = MarkdownBlocks.parse(md)
        #expect(blocks == [
            .heading(level: 1, text: "Titre"),
            .paragraph("Première ligne suite de la même phrase."),
            .heading(level: 2, text: "Section"),
            .bullet("une puce"),
            .bullet("**deux** puces"),
            .paragraph("Fin."),
        ])
        #expect(MarkdownBlocks.body(md).first == .heading(level: 2, text: "Section") || MarkdownBlocks.body(md).first == .paragraph("Première ligne suite de la même phrase."))
        #expect(!MarkdownBlocks.body(md).contains(.heading(level: 1, text: "Titre")))
        #expect(String(MarkdownView.inline("**deux** puces").characters) == "deux puces")
        #expect(MarkdownBlocks.parse("").isEmpty)
    }

    @Test("Textes embarqués : les six articles de shared/texts, chacun avec son fichier et son titre")
    func bundledTexts() {
        let articles = Texts.index()
        #expect(articles.map(\.id) == [
            "comment-ca-marche", "donnees-et-sources", "especes", "cueillir-sans-nuire", "confidentialite", "mentions-legales",
        ])
        #expect(articles.first { $0.listsSpecies }?.id == "especes")
        for article in articles {
            let body = Texts.body(of: article)
            #expect(body?.hasPrefix("# \(article.title)\n") == true, "\(article.id)")
        }
        #expect(Texts.body(of: articles[2])?.contains("pharmacien") == true)
    }

    @Test("Fiche d'espèce : bloc about décodé, absent toléré, photo nulle tant qu'elle n'est pas choisie")
    func about() throws {
        let plain = try Fixtures.decode(Species.self, Fixtures.speciesJSON(id: "boletus_edulis", group: ("cepes", "Cèpes"), fr: "Cèpe de Bordeaux", la: "Boletus edulis"))
        #expect(plain.about == nil)
        let withAbout = Fixtures.speciesJSON(id: "boletus_edulis", group: ("cepes", "Cèpes"), fr: "Cèpe de Bordeaux", la: "Boletus edulis")
            .replacingOccurrences(of: "\"schema_version\": 1,", with: "\"schema_version\": 1, \"about\": \(Fixtures.aboutJSON),")
        let species = try Fixtures.decode(Species.self, withAbout)
        let about = try #require(species.about)
        #expect(about.summary.hasPrefix("Le cèpe"))
        #expect(about.confusions.map(\.latin) == ["Tylopilus felleus"])
        #expect(about.confusions[0].refs == ["courtecuisse2013"])
        #expect(about.references["courtecuisse2013"]?.contains("Courtecuisse") == true)
        #expect(about.photo == nil)
    }
}

/// Étape A (spec › Produit, 6 nov. 2026) : plus rien de faux à l'écran. Les coins et les
/// observations partent sur le serveur sous un identifiant pseudonyme : ni « rien n'est collecté »,
/// ni « anonyme », dans l'accueil comme dans les textes du Guide embarqués.
@MainActor
struct HonestTextsTests {
    @Test("Accueil : « Vos coins restent à vous », identifiant pseudonyme, jamais « anonyme »")
    func onboarding() {
        let cards = OnboardingView.cards
        #expect(cards.count == 3)
        #expect(cards.contains { $0.title == "Vos coins restent à vous" })
        #expect(!cards.contains { $0.title.localizedCaseInsensitiveContains("rien n'est collecté") })
        #expect(!cards.contains { $0.text.localizedCaseInsensitiveContains("anonyme") })
        #expect(cards.contains { $0.text.contains("pseudonyme") })
    }

    @Test("Textes du Guide embarqués : la confidentialité parle d'identifiant pseudonyme")
    func guideTexts() throws {
        let article = try #require(Texts.index().first { $0.id == "confidentialite" })
        let markdown = try #require(Texts.body(of: article))
        #expect(markdown.contains("pseudonyme"))
        #expect(!markdown.contains("anonyme créé"))
    }

    @Test("Mentions légales (étape C) : l'éditeur et l'adresse de contact, en lien")
    func legalNotice() throws {
        let article = try #require(Texts.index().first { $0.id == "mentions-legales" })
        let markdown = try #require(Texts.body(of: article))
        #expect(markdown.contains("Adrien Humilière"))
        #expect(markdown.contains("[hello@champis.app](mailto:hello@champis.app)"))
        let link = MarkdownView.inline("Contact : [hello@champis.app](mailto:hello@champis.app).").runs.compactMap { $0.link }.first
        #expect(link?.absoluteString == "mailto:hello@champis.app")
    }
}

