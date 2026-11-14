import Foundation

/// Cache disque des tuiles lues (skill `offline`) : `Application Support/Champis/tiles/<nom du
/// fichier PMTiles>/<z>/<x>_<y>.png`, exclu de la sauvegarde iCloud. Le nom du fichier porte déjà
/// le hash des départements et la version du scoring : un nouveau manifeste donne un nouveau
/// dossier, et `prune` efface les autres. Une tuile absente est mémorisée par un fichier vide pour ne
/// pas la redemander. Premier étage du hors ligne : ce qui a été vu reste lisible sans réseau.
///
/// Un jeu republié garde son nom (l'empreinte du nom est celle des départements, pas du contenu ;
/// même défaut corrigé côté serveur le 13 nov. 2026, `_stale` du relais des tuiles). Chaque dossier
/// porte donc le tampon de la version dont viennent ses tuiles (`version.json` : taille totale du
/// fichier et ETag) : un dossier dont le tampon ne correspond plus à ce que le manifeste (`bytes`)
/// ou le serveur annonce est effacé, jamais complété par des tuiles d'une autre version.
nonisolated struct DiskTileCache: Sendable {
    /// Version d'un fichier PMTiles : sa taille totale et son ETag, selon ce qui est connu.
    nonisolated struct Stamp: Codable, Equatable, Sendable {
        var bytes: Int64?
        var etag: String?

        /// Faux dès qu'une taille ou un ETag connus des deux côtés diffèrent.
        func matches(_ other: Stamp) -> Bool {
            if let bytes, let theirs = other.bytes, bytes != theirs { return false }
            if let etag, let theirs = other.etag, etag != theirs { return false }
            return true
        }

        /// Ce tampon complété par ce que `other` sait de plus.
        func merged(with other: Stamp) -> Stamp {
            Stamp(bytes: bytes ?? other.bytes, etag: etag ?? other.etag)
        }
    }

    static let stampName = "version.json"

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

    /// Dossier d'un fichier PMTiles pour y lire, écrire ou l'effacer : `file` vient du manifeste du
    /// serveur, il doit être un simple nom (`SafePath.isComponent`) et rester sous la racine.
    private func safeDirectory(for file: String) throws -> URL {
        guard SafePath.isComponent(file) else { throw SafePath.Refused(name: file) }
        return try SafePath.checked(directory(for: file), in: root)
    }

    private func url(file: String, z: Int, x: Int, y: Int) throws -> URL {
        try safeDirectory(for: file).appending(path: "\(z)", directoryHint: .isDirectory).appending(path: "\(x)_\(y).png")
    }

    func read(file: String, z: Int, x: Int, y: Int) -> Hit {
        guard let target = try? url(file: file, z: z, x: x, y: y), let data = try? Data(contentsOf: target) else { return .miss }
        return data.isEmpty ? .absent : .tile(data)
    }

    /// Tampon du dossier de `file` ; `nil` s'il n'en a pas (dossier absent, ou d'avant les tampons).
    func stamp(file: String) -> Stamp? {
        guard let directory = try? safeDirectory(for: file),
              let data = try? Data(contentsOf: directory.appending(path: Self.stampName))
        else { return nil }
        return try? JSONDecoder().decode(Stamp.self, from: data)
    }

    func setStamp(_ stamp: Stamp, file: String) throws {
        let directory = try safeDirectory(for: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(stamp).write(to: directory.appending(path: Self.stampName), options: .atomic)
    }

    /// Efface le dossier de `file` (tuiles et tampon).
    func remove(file: String) throws {
        let directory = try safeDirectory(for: file)
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Garde le dossier de `file` s'il vient de la version attendue, sinon l'efface (un dossier
    /// sans tampon ne dit pas de quelle version il vient : effacé aussi). Renvoie le tampon gardé.
    @discardableResult
    func validate(file: String, against expected: Stamp) -> Stamp? {
        if let current = stamp(file: file), current.matches(expected) {
            return current
        }
        try? remove(file: file)
        return nil
    }

    /// Écrit la tuile (ou son absence, `nil`) de façon atomique. Avec `stamp`, la version dont
    /// vient la tuile : un dossier d'une autre version est d'abord effacé, puis tamponné.
    func write(file: String, z: Int, x: Int, y: Int, data: Data?, stamp: Stamp? = nil) throws {
        let target = try url(file: file, z: z, x: x, y: y)
        if let stamp {
            if let current = self.stamp(file: file), current.matches(stamp) {
                let merged = current.merged(with: stamp)
                if merged != current {
                    try setStamp(merged, file: file)
                }
            } else {
                try remove(file: file)
                try setStamp(stamp, file: file)
            }
        }
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
            try FileManager.default.removeItem(at: try SafePath.checked(directory(for: name), in: root))
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
            try FileManager.default.removeItem(at: try SafePath.checked(directory(for: name), in: root))
        }
    }
}
