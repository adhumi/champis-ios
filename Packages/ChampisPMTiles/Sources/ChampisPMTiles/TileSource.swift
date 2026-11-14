import Foundation

/// D'où viennent les octets : un fichier téléchargé (hors ligne) ou un serveur qui accepte `Range`.
/// Même interface dans les deux cas, pour que le lecteur et la carte ne fassent pas la différence.
public protocol TileSource: Sendable {
    func read(offset: UInt64, length: Int) async throws -> Data
}

/// Fichier PMTiles sur disque (téléchargement par département, skill `offline`).
public actor LocalFileSource: TileSource {
    private let handle: FileHandle

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else {
            if length == 0 { return Data() }
            throw PMTilesError.truncated("fichier : longueur négative")
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else {
            throw PMTilesError.truncated("fichier : \(data.count) octets lus sur \(length) à \(offset)")
        }
        return data
    }

    deinit {
        try? handle.close()
    }
}

/// Fichier PMTiles distant lu par requêtes `Range` (URL présignée du bucket ou relais `/tiles/{nom}`
/// de l'API, selon le manifeste `GET /tiles`).
public struct RemoteRangeSource: TileSource {
    public let url: URL
    public let session: URLSession
    public let headers: [String: String]

    public init(url: URL, session: URLSession = .shared, headers: [String: String] = [:]) {
        self.url = url
        self.session = session
        self.headers = headers
    }

    /// Fin de plage au-delà de laquelle une réponse 200 (serveur qui ignore `Range` et envoie le
    /// fichier entier) est refusée au lieu d'être chargée en mémoire : un PMTiles France pèse des
    /// gigaoctets.
    public static let maxWholeResponseBytes = 1 << 20

    /// Valeur de l'en-tête `Range` pour `length` octets à partir de `offset` ; `nil` si la plage est
    /// vide ou dépasse 64 bits (décalage aberrant lu dans un fichier malformé).
    static func rangeHeader(offset: UInt64, length: Int) -> String? {
        guard length > 0 else { return nil }
        let (last, overflow) = offset.addingReportingOverflow(UInt64(length) - 1)
        guard !overflow else { return nil }
        return "bytes=\(offset)-\(last)"
    }

    /// Le corps est lu au fil de l'eau : au plus `length` octets pour un 206, et un 200 n'est lu que
    /// jusqu'à la fin de la plage, si elle tient sous `maxWholeResponseBytes`.
    public func read(offset: UInt64, length: Int) async throws -> Data {
        if length == 0 { return Data() }
        guard let range = Self.rangeHeader(offset: offset, length: length) else {
            throw PMTilesError.truncated("Range : plage invalide (\(length) octets à \(offset))")
        }
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PMTilesError.rangeUnavailable(0) }
        switch http.statusCode {
        case 206:
            let data = try await Self.collect(bytes, upTo: length)
            guard data.count == length else {
                throw PMTilesError.truncated("Range : \(data.count) octets sur \(length)")
            }
            return data
        case 200:
            // Serveur sans Range : il envoie le fichier depuis son début. Acceptable quand la plage
            // tient dans les premiers octets (petit fichier, tests), et on s'arrête à la fin de la
            // plage ; jamais pour une plage plus loin, qui ferait charger un vrai jeu en entier.
            guard let start = Int(exactly: offset), start <= Self.maxWholeResponseBytes - length else {
                throw PMTilesError.rangeUnavailable(200)
            }
            let announced = http.expectedContentLength
            guard announced < 0 || announced >= Int64(start + length) else {
                throw PMTilesError.truncated("Range ignoré")
            }
            let data = try await Self.collect(bytes, upTo: start + length)
            guard data.count == start + length else { throw PMTilesError.truncated("Range ignoré") }
            return data.subdata(in: start..<(start + length))
        default:
            throw PMTilesError.rangeUnavailable(http.statusCode)
        }
    }

    /// Au plus `limit` octets du corps ; la lecture s'arrête là, le reste n'est pas reçu.
    private static func collect(_ bytes: URLSession.AsyncBytes, upTo limit: Int) async throws -> Data {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(limit)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= limit { break }
        }
        return Data(buffer)
    }
}
