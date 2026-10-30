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

    public func read(offset: UInt64, length: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PMTilesError.rangeUnavailable(0) }
        switch http.statusCode {
        case 206:
            guard data.count >= length else {
                throw PMTilesError.truncated("Range : \(data.count) octets sur \(length)")
            }
            return data.count == length ? data : data.prefix(length)
        case 200:
            // Serveur sans Range : on a tout reçu, on découpe (coûteux, mais correct)
            let start = Int(offset)
            guard data.count >= start + length else { throw PMTilesError.truncated("Range ignoré") }
            return data.subdata(in: start..<(start + length))
        default:
            throw PMTilesError.rangeUnavailable(http.statusCode)
        }
    }
}
