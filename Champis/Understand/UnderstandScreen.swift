import SwiftUI

/// Onglet Comprendre (refonte UX) : la réponse à « pourquoi ? ». Au lot 1, les textes déjà
/// présents dans l'app (cadre légal, confidentialité) et un résumé du modèle ; les cinq articles
/// complets, partagés avec le site, arrivent au lot 4.
struct UnderstandScreen: View {
    let model: MapModel
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var showSettings = false
    @State private var showLegalNotice = false

    var body: some View {
        NavigationStack {
            List {
                Section("Comment ça marche") {
                    Text(
                        "La carte croise trois choses : le terrain (essences, sol, altitude, exposition, " +
                        "calculé une fois pour toute la France), la météo des dernières semaines et des " +
                        "prochains jours, et la saison de chaque espèce. Le résultat se lit avec cinq " +
                        "couleurs, du vert foncé (excellent) au rouge (très faible). Un endroit transparent " +
                        "est hors forêt ou sans donnée."
                    )
                    if let catalog = model.catalog {
                        LabeledContent("Espèces suivies", value: "\(catalog.species.count)")
                    }
                }
                Section("Les données") {
                    Text(
                        "Forêts : IGN BD Forêt V2. Relief : Copernicus DEM. Sols : SoilGrids (ISRIC). " +
                        "Météo : Open-Meteo. Occurrences de contrôle : GBIF. Toutes en licence ouverte ; " +
                        "les crédits complets sont sur le site."
                    )
                }
                Section(LegalNotice.title) {
                    Text(LegalNotice.text)
                }
                Section("Confidentialité") {
                    Text(
                        "Pas de compte. Vos coins et vos observations sont liés à un identifiant anonyme " +
                        "créé par l'app, jamais partagés, et vous pouvez tout effacer depuis les réglages."
                    )
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
