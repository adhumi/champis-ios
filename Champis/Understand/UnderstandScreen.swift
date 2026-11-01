import SwiftUI

/// Onglet Comprendre (refonte UX, lot 4) : la réponse à « pourquoi ? ». Cinq articles embarqués
/// (`shared/texts/`, lisibles hors ligne) ; « Les espèces » ouvre les fiches de `GET /species`.
/// Les réglages, réduits, sont ici et dans chaque onglet.
struct UnderstandScreen: View {
    let model: MapModel
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var showSettings = false
    @State private var showLegalNotice = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Texts.index()) { article in
                        NavigationLink {
                            ArticleView(article: article, model: model)
                        } label: {
                            Label(article.title, systemImage: article.icon)
                        }
                    }
                } footer: {
                    Text("Les mêmes textes que le site champis.adhumi.fr, lisibles sans réseau.")
                }
            }
            .navigationTitle("Comprendre")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model, apiBaseURL: $apiBaseURL, showLegalNotice: $showLegalNotice)
            }
            .alert(LegalNotice.title, isPresented: $showLegalNotice) {
                Button("OK") {}
            } message: {
                Text(LegalNotice.text)
            }
        }
    }
}
