import Foundation

/// Cache disque des tuiles lues (skill `offline`) : `Application Support/Champis/tiles/<nom du
/// fichier PMTiles>/<z>/<x>_<y>.png`, exclu de la sauvegarde iCloud. Le nom du fichier porte déjà
/// le hash des départements et la version du scoring : un nouveau manifeste donne un nouveau
/// dossier, et `prune` efface les autres. Une tuile absente est mémorisée par un fichier vide pour ne
/// pas la redemander. Premier étage du hors ligne : ce qui a été vu reste lisible sans réseau.
nonisolated struct DiskTileCache: Sendable {
    nonisolated enum Hit: Equatable, Sendable {
        case tile(Data)
        case absent
        case miss
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Emplacement par défaut, créé et exclu de la sauvegarde.
    static func `default`() throws -> DiskTileCache {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = support.appending(path: "Champis/tiles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        return DiskTileCache(root: root)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func directory(for file: String) -> URL {
        root.appending(path: file, directoryHint: .isDirectory)
    }

    private func url(file: String, z: Int, x: Int, y: Int) -> URL {
        directory(for: file).appending(path: "\(z)", directoryHint: .isDirectory).appending(path: "\(x)_\(y).png")
    }

    func read(file: String, z: Int, x: Int, y: Int) -> Hit {
        guard let data = try? Data(contentsOf: url(file: file, z: z, x: x, y: y)) else { return .miss }
        return data.isEmpty ? .absent : .tile(data)
    }

    /// Écrit la tuile (ou son absence, `nil`) de façon atomique.
    func write(file: String, z: Int, x: Int, y: Int, data: Data?) throws {
        let target = url(file: file, z: z, x: x, y: y)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data()).write(to: target, options: .atomic)
    }

    /// Dossiers présents (un par fichier PMTiles).
    func files() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Efface les dossiers qui ne sont plus dans le manifeste ; renvoie leurs noms.
    @discardableResult
    func prune(keeping files: Set<String>) throws -> [String] {
        var removed: [String] = []
        for name in self.files() where !files.contains(name) {
            try FileManager.default.removeItem(at: directory(for: name))
            removed.append(name)
        }
        return removed
    }

    /// Taille totale en octets (fichiers vides compris, négligeables).
    func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func removeAll() throws {
        for name in files() {
            try FileManager.default.removeItem(at: directory(for: name))
        }
    }
}
