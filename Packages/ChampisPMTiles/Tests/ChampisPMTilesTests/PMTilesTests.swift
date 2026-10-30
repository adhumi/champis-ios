import CryptoKit
import Foundation
import Testing
@testable import ChampisPMTiles

/// Fixtures produites par la bibliothèque `pmtiles` du pipeline et l'encodeur PNG du pipeline
/// (`fixture.pmtiles`, `fixture.json`, `pngs.json`) : le lecteur maison doit lire exactement ce que
/// le pipeline écrit.
private struct Fixture: Decodable {
    struct Tile: Decodable {
        struct Sample: Decodable {
            let px: Int
            let py: Int
            let value: UInt8?
        }
        let z: Int, x: Int, y: Int
        let tileId: UInt64
        let sha256: String
        let bytes: Int
        let samples: [Sample]
        enum CodingKeys: String, CodingKey { case z, x, y, sha256, bytes, samples, tileId = "tile_id" }
    }
    struct Header: Decodable {
        let minZoom: Int, maxZoom: Int
        let tileType: String, tileCompression: String
        let minLonE7: Int32, maxLatE7: Int32
        enum CodingKeys: String, CodingKey {
            case minZoom = "min_zoom", maxZoom = "max_zoom", tileType = "tile_type"
            case tileCompression = "tile_compression", minLonE7 = "min_lon_e7", maxLatE7 = "max_lat_e7"
        }
    }
    struct Hilbert: Decodable {
        let z: Int, x: Int, y: Int
        let tileId: UInt64
        enum CodingKeys: String, CodingKey { case z, x, y, tileId = "tile_id" }
    }
    let tiles: [Tile]
    let absent: [[Int]]
    let header: Header
    let hilbert: [Hilbert]
    let nodata: UInt8
}

private func resourceURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
                 "ressource \(name) absente")
}

private func fixture() throws -> Fixture {
    try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: resourceURL("fixture.json")))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct HilbertTests {
    @Test("Identifiants de tuile de la spécification, et leur inverse")
    func ids() throws {
        for h in try fixture().hilbert {
            #expect(TileID.fromZXY(z: h.z, x: h.x, y: h.y) == h.tileId, "\(h.z)/\(h.x)/\(h.y)")
            let back = TileID.toZXY(h.tileId)
            #expect(back.z == h.z && back.x == h.x && back.y == h.y)
        }
        #expect(TileID.fromZXY(z: 0, x: 0, y: 0) == 0)
        #expect(TileID.fromZXY(z: 1, x: 0, y: 0) == 1 && TileID.fromZXY(z: 2, x: 0, y: 0) == 5)
    }
}

struct DirectoryTests {
    @Test("Sérialisation et désérialisation : deltas, séries, décalages contigus")
    func roundTrip() throws {
        let entries = [
            DirectoryEntry(tileID: 5, offset: 0, length: 100, runLength: 1),
            DirectoryEntry(tileID: 6, offset: 100, length: 50, runLength: 3),  // 6, 7, 8 identiques
            DirectoryEntry(tileID: 20, offset: 400, length: 10, runLength: 1),  // non contigu
            DirectoryEntry(tileID: 100, offset: 0, length: 30, runLength: 0),  // répertoire feuille
        ]
        let back = try Directory.deserialize(Directory.serialize(entries))
        #expect(back == entries)
        #expect(Directory.find(entries, tileID: 5) == entries[0])
        #expect(Directory.find(entries, tileID: 8) == entries[1])  // couvert par la série
        #expect(Directory.find(entries, tileID: 9) == nil)
        #expect(Directory.find(entries, tileID: 20) == entries[2])
        #expect(Directory.find(entries, tileID: 150) == entries[3])  // au-delà : la feuille
        #expect(Directory.find(entries, tileID: 2) == nil)
        #expect(Directory.find([], tileID: 1) == nil)
    }

    @Test("Varint : encodage LEB128")
    func varint() throws {
        for v: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, UInt64(UInt32.max), 1 << 40] {
            var r = ByteReader(Varint.encode(v))
            #expect(try r.readVarint() == v)
            #expect(r.remaining == 0)
        }
    }
}

/// Source en mémoire : la fixture entière, servie par plages comme un fichier ou un serveur.
private struct MemorySource: TileSource {
    let data: Data
    let log: Log
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var ranges: [(UInt64, Int)] = []
        func add(_ r: (UInt64, Int)) { lock.lock(); ranges.append(r); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ranges.count }
    }
    func read(offset: UInt64, length: Int) async throws -> Data {
        log.add((offset, length))
        let start = Int(offset)
        guard start + length <= data.count else { throw PMTilesError.truncated("mémoire") }
        return data.subdata(in: start..<(start + length))
    }
}

struct ReaderTests {
    @Test("En-tête et répertoire racine gzip du fichier produit par le pipeline")
    func header() async throws {
        let f = try fixture()
        let reader = PMTilesReader(source: try LocalFileSource(url: resourceURL("fixture.pmtiles")))
        let h = try await reader.readHeader()
        #expect(h.minZoom == f.header.minZoom && h.maxZoom == f.header.maxZoom)
        #expect(h.tileType == .png && h.tileCompression == .none && h.internalCompression == .gzip)
        #expect(h.minLonE7 == f.header.minLonE7 && h.maxLatE7 == f.header.maxLatE7)
        #expect(abs(h.bounds.minLon - 5.5) < 1e-6)
        let root = try await reader.rootDirectory()
        #expect(root.count == f.tiles.count && root.allSatisfy { !$0.isLeafDirectory })
        let meta = try JSONSerialization.jsonObject(with: try await reader.metadata()) as? [String: Any]
        #expect(meta?["name"] as? String == "fixture champis")
    }

    @Test("Chaque tuile revient octet pour octet ; les absentes sont nil")
    func tiles() async throws {
        let f = try fixture()
        let reader = PMTilesReader(source: try LocalFileSource(url: resourceURL("fixture.pmtiles")))
        for t in f.tiles {
            let data = try #require(try await reader.tile(z: t.z, x: t.x, y: t.y), "\(t.z)/\(t.x)/\(t.y)")
            #expect(data.count == t.bytes && sha256(data) == t.sha256)
            let png = try PNGDecoder.decode(data)
            #expect(png.width == 256 && png.height == 256 && png.channels == 2)
            for s in t.samples {
                let (v, a) = png.valueAndAlpha(x: s.px, y: s.py)
                if let expected = s.value {
                    #expect(v == expected && a == 255, "pixel \(s.px),\(s.py)")
                } else {
                    #expect(a == 0, "nodata attendu en \(s.px),\(s.py)")  // hors forêt : alpha 0
                }
            }
        }
        for a in f.absent {
            #expect(try await reader.tile(z: a[0], x: a[1], y: a[2]) == nil)
        }
        #expect(try await reader.tile(z: 3, x: 0, y: 0) == nil)  // sous min_zoom : pas de requête
    }

    @Test("Une tuile = une lecture de plage ; en-tête et racine lus une seule fois")
    func rangeEconomy() async throws {
        let f = try fixture()
        let src = MemorySource(data: try Data(contentsOf: resourceURL("fixture.pmtiles")), log: .init())
        let reader = PMTilesReader(source: src)
        _ = try await reader.tile(z: f.tiles[0].z, x: f.tiles[0].x, y: f.tiles[0].y)
        #expect(src.log.count == 3)  // en-tête, racine, données
        _ = try await reader.tile(z: f.tiles[1].z, x: f.tiles[1].x, y: f.tiles[1].y)
        #expect(src.log.count == 4)
        _ = try await reader.tile(z: 7, x: 66, y: 44)  // absente : aucune lecture de données
        #expect(src.log.count == 4)
    }

    @Test("Répertoires feuilles et compression « none » construits de toutes pièces")
    func leafDirectories() async throws {
        // Fichier synthétique : en-tête, racine → une feuille, feuille → deux tuiles.
        let tileA = Data([1, 2, 3, 4]), tileB = Data([9, 9])
        let tileData = tileA + tileB
        let leaf = Directory.serialize([
            DirectoryEntry(tileID: TileID.fromZXY(z: 6, x: 33, y: 22), offset: 0, length: 4, runLength: 1),
            DirectoryEntry(tileID: TileID.fromZXY(z: 7, x: 66, y: 45), offset: 4, length: 2, runLength: 1),
        ])
        let root = Directory.serialize([
            DirectoryEntry(tileID: TileID.fromZXY(z: 6, x: 33, y: 22), offset: 0, length: UInt32(leaf.count), runLength: 0),
        ])
        var header = [UInt8](repeating: 0, count: 127)
        header.replaceSubrange(0..<7, with: Array("PMTiles".utf8))
        header[7] = 3
        func put(_ v: UInt64, at: Int) { for i in 0..<8 { header[at + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
        let rootOffset = UInt64(127), leafOffset = rootOffset + UInt64(root.count)
        let dataOffset = leafOffset + UInt64(leaf.count)
        put(rootOffset, at: 8); put(UInt64(root.count), at: 16)
        put(leafOffset, at: 40); put(UInt64(leaf.count), at: 48)
        put(dataOffset, at: 56); put(UInt64(tileData.count), at: 64)
        header[97] = 1  // internal_compression none
        header[98] = 1  // tile_compression none
        header[99] = 2  // png
        header[100] = 6; header[101] = 7
        let file = Data(header) + root + leaf + tileData
        let reader = PMTilesReader(source: MemorySource(data: file, log: .init()))
        #expect(try await reader.tile(z: 6, x: 33, y: 22) == tileA)
        #expect(try await reader.tile(z: 7, x: 66, y: 45) == tileB)
        #expect(try await reader.tile(z: 7, x: 66, y: 46) == nil)
    }

    @Test("Un fichier qui n'est pas un PMTiles est refusé")
    func notPMTiles() async throws {
        let reader = PMTilesReader(source: MemorySource(data: Data(repeating: 0, count: 200), log: .init()))
        await #expect(throws: PMTilesError.notPMTiles) { try await reader.readHeader() }
    }
}

/// Serveur HTTP factice qui honore `Range` sur la fixture, pour `RemoteRangeSource`.
final class RangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RangeURLProtocol.requests += 1
        let body = RangeURLProtocol.body
        var status = 200
        var slice = body
        if let range = request.value(forHTTPHeaderField: "Range"),
           let m = range.wholeMatch(of: /bytes=(\d+)-(\d+)/) {
            let a = Int(m.1)!, b = Int(m.2)!
            slice = body.subdata(in: a..<min(b + 1, body.count))
            status = 206
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Length": String(slice.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct RemoteSourceTests {
    @Test("Lecture par requêtes Range à travers URLSession")
    func remote() async throws {
        let f = try fixture()
        RangeURLProtocol.body = try Data(contentsOf: resourceURL("fixture.pmtiles"))
        RangeURLProtocol.requests = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeURLProtocol.self]
        let session = URLSession(configuration: config)
        let source = RemoteRangeSource(url: URL(string: "https://tiles.example/T-fixture.pmtiles")!, session: session)
        let reader = PMTilesReader(source: source)
        let t = f.tiles[0]
        let data = try #require(try await reader.tile(z: t.z, x: t.x, y: t.y))
        #expect(sha256(data) == t.sha256)
        #expect(RangeURLProtocol.requests == 3)
    }
}

/// PNG de chaque filtre et de chaque nombre de canaux, et une vraie tuile du pipeline.
private struct PNGCase: Decodable {
    let channels: Int
    let filter: Int
    let width: Int
    let height: Int
    let png: String
    let pixels: String?
    let graySha256: String?
    let nodata: UInt8?
    enum CodingKeys: String, CodingKey {
        case channels, filter, width, height, png, pixels, nodata, graySha256 = "gray_sha256"
    }
}

struct PNGDecoderTests {
    @Test("Chaque filtre (0–4), gris, gris+alpha, RGB, RGBA : octets identiques")
    func filters() throws {
        let cases = try JSONDecoder().decode([PNGCase].self, from: Data(contentsOf: resourceURL("pngs.json")))
        #expect(cases.count == 21)
        for c in cases {
            let img = try PNGDecoder.decode(try #require(Data(base64Encoded: c.png)))
            #expect(img.width == c.width && img.height == c.height && img.channels == c.channels, "filtre \(c.filter)")
            if let pixels = c.pixels {
                #expect(img.data == [UInt8](try #require(Data(base64Encoded: pixels))), "canaux \(c.channels), filtre \(c.filter)")
            } else {
                // tuile du pipeline : le canal gris porte la valeur brute (nodata inclus), alpha 0 hors forêt
                var gray = [UInt8](repeating: 0, count: 256 * 256)
                for i in 0..<gray.count { gray[i] = img.data[i * 2] }
                #expect(sha256(Data(gray)) == c.graySha256)
                let (v, a) = img.valueAndAlpha(x: 0, y: 0)
                #expect(v == c.nodata && a == 0)
            }
        }
    }

    @Test("Refus explicite : signature, profondeur, entrelacement")
    func refusals() {
        #expect(throws: PNGError.badSignature) { try PNGDecoder.decode(Data([0, 1, 2, 3, 4, 5, 6, 7, 8])) }
        var bad = Data([137, 80, 78, 71, 13, 10, 26, 10])
        bad += Data([0, 0, 0, 13]) + Data("IHDR".utf8) + Data([0, 0, 0, 1, 0, 0, 0, 1, 16, 0, 0, 0, 0]) + Data([0, 0, 0, 0])
        #expect(throws: PNGError.self) { try PNGDecoder.decode(bad) }
    }
}
