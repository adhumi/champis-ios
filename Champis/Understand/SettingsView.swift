import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#endif

/// Réglages réduits (refonte UX, lot 4) : Notifications, Départements embarqués, Mes données,
/// Soutenir Champis, À propos. L'adresse de l'API est un réglage de développement, révélé par
/// cinq tapes sur la version ; l'opacité est fixe ; le fond satellite est dans le menu de calque ;
/// le hors ligne se propose à la création d'un coin.
struct SettingsView: View {
    static let supportURL = URL(string: "https://champis.cc/soutenir")!
    static let developerTaps = 5

    @Bindable var model: MapModel
    @Binding var apiBaseURL: String
    @Binding var showLegalNotice: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    @State private var notifications: UNAuthorizationStatus?
    @State private var versionTaps = 0
    @AppStorage("developerSettings") private var developerSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Notifications", value: notificationsText)
                    if notifications != .authorized {
                        Button("Ouvrir les réglages du système") { openSystemSettings() }
                    }
                } footer: {
                    Text("Une notification le matin, vers 7 h, quand l'un de vos coins passe à bon ou excellent. Calculée par le serveur : l'app ne tourne pas en arrière-plan.")
                }
                Section {
                    NavigationLink {
                        OfflineView(offline: model.offline, model: model)
                    } label: {
                        LabeledContent("Départements embarqués", value: "\(model.offline.departments.filter(\.complete).count)")
                    }
                } footer: {
                    Text("Un département embarqué se lit sans réseau, météo du téléchargement comprise. L'app le propose aussi à la création d'un coin.")
                }
                Section {
                    LabeledContent("Observations", value: "\(model.field.observations.count)")
                    LabeledContent("Coins", value: "\(model.field.coins.count)")
                    Button("Supprimer mes observations et mes coins", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.field.userID == nil)
                    if let status = model.field.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mes données")
                } footer: {
                    Text("Privées, liées à un identifiant anonyme de l'app. La suppression efface tout sur le serveur et sur l'appareil.")
                }
                Section {
                    Link(destination: Self.supportURL) {
                        Label("Soutenir Champis", systemImage: "heart")
                    }
                } footer: {
                    Text("Serveurs et données sont financés par des dons. Pas de publicité, pas de compte.")
                }
                Section("À propos") {
                    Button {
                        versionTaps += 1
                        if versionTaps >= Self.developerTaps {
                            developerSettings = true
                        }
                    } label: {
                        LabeledContent("Version", value: Self.version)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(developerSettings ? "" : "Cinq tapes révèlent les réglages de développement")
                    if let catalog = model.catalog {
                        LabeledContent("Modèle", value: catalog.scoringVersion)
                    }
                    Button(LegalNotice.title) {
                        dismiss()
                        showLegalNotice = true
                    }
                    if let article = Texts.index().first(where: { $0.id == "donnees-et-sources" }) {
                        NavigationLink("Licences des données") {
                            ArticleView(article: article, model: model)
                        }
                    }
                }
                if developerSettings {
                    Section {
                        TextField("Adresse de l'API", text: $apiBaseURL)
                            .autocorrectionDisabled()
                        LabeledContent("Tuiles en cache", value: cacheSizeText)
                        Button("Vider le cache des tuiles", role: .destructive) {
                            Task { await model.clearTileCache() }
                        }
                        Button("Masquer ces réglages") { developerSettings = false }
                    } header: {
                        Text("Développement")
                    }
                }
            }
            .confirmationDialog(
                "Supprimer toutes mes observations et mes coins ?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Tout supprimer", role: .destructive) {
                    let field = model.field
                    Task { await field.deleteAll() }
                }
            } message: {
                Text("Le serveur efface vos lignes, l'appareil aussi. Il n'y a pas de retour.")
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task {
                notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if developerSettings {
                    await model.refreshTileCacheSize()
                }
            }
        }
    }

    private var notificationsText: String {
        switch notifications {
        case .authorized, .provisional: "Activées"
        case .denied: "Refusées"
        case .notDetermined: "Demandées au premier coin"
        default: "…"
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            openURL(url)
        }
        #endif
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private var cacheSizeText: String {
        guard let size = model.tileCacheSize else { return "…" }
        return size.formatted(.byteCount(style: .file))
    }
}
