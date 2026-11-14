import Foundation
import Testing
@testable import ChampisPMTiles

/// Fichiers altérés (audit du 13 nov. 2026) : un PMTiles ou un PNG malformé lève une erreur du
/// paquet, il n'arrête jamais le processus. Les cas partent du fichier produit par le pipeline
/// (`fixture.pmtiles`) : octets mutés, en-têtes aberrants, fichier ou répertoire tronqué.

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "fixture.pmtiles", withExtension: nil))
    return try Data(contentsOf: url)
}

/// Source en mémoire qui ne fait confiance à aucun décalage : ceux d'un fichier altéré sont aberrants.
private struct SafeMemorySource: TileSource {
    let data: Data

    func read(offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0, let start = Int(exactly: offset), start <= data.count, length <= data.count - start else {
            throw PMTilesError.truncated("mémoire")
        }
        return data.subdata(in: start..<(start + length))
    }
}

private func makeReader(_ data: Data) -> PMTilesReader {
    PMTilesReader(source: SafeMemorySource(data: data))
}

/// Écrit un entier de 64 bits petit-boutiste à `offset`.
private func put(_ value: UInt64, at offset: Int, in data: inout Data) {
    for i in 0..<8 {
        data[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF)
    }
}

/// Positions des champs de l'en-tête PMTiles v3.
private enum Field {
    static let rootOffset = 8
    static let rootLength = 16
    static let metadataLength = 32
    static let leafOffset = 40
    static let tileDataOffset = 56
    static let internalCompression = 97
    static let tileCompression = 98
    static let minZoom = 100
    static let maxZoom = 101
}

/// La première tuile de la fixture : 6/33/22, à l'offset 0 des données.
private let firstTile = (z: 6, x: 33, y: 22)

struct MalformedHeaderTests {
    @Test("Longueurs et décalages aberrants de l'en-tête : une erreur, jamais un arrêt", arguments: [
        (Field.rootLength, UInt64.max),
        (Field.rootLength, UInt64(1) << 63),
        (Field.rootLength, UInt64(ChampisPMTiles.maxDirectoryBytes) + 1),
        (Field.rootLength, UInt64(0)),
        (Field.rootLength, UInt64(20)),  // gzip tronqué au début de son flux
        (Field.rootOffset, UInt64.max),
        (Field.rootOffset, UInt64.max - 10),
        (Field.rootOffset, UInt64(1) << 40),
        (Field.tileDataOffset, UInt64.max),
        (Field.tileDataOffset, UInt64(1) << 62),
    ])
    func sizes(field: Int, value: UInt64) async throws {
        var data = try fixtureData()
        put(value, at: field, in: &data)
        let reader = makeReader(data)
        await #expect(throws: PMTilesError.self) {
            try await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y)
        }
    }

    @Test("Répertoire racine au-delà du plafond : refusé avant toute lecture")
    func directoryCap() async throws {
        var data = try fixtureData()
        put(UInt64(ChampisPMTiles.maxDirectoryBytes) + 1, at: Field.rootLength, in: &data)
        let reader = makeReader(data)
        await #expect(throws: PMTilesError.self) { try await reader.rootDirectory() }
        var huge = try fixtureData()
        put(UInt64.max, at: Field.metadataLength, in: &huge)
        let other = PMTilesReader(source: SafeMemorySource(data: huge))
        await #expect(throws: PMTilesError.self) { try await other.metadata() }
    }

    @Test("Signature, version et compressions altérées")
    func kinds() async throws {
        let original = try fixtureData()

        var magic = original
        magic[0] = 0x50 ^ 0xFF
        let notPMTiles = makeReader(magic)
        await #expect(throws: PMTilesError.notPMTiles) { try await notPMTiles.readHeader() }

        var version = original
        version[7] = 4
        let future = makeReader(version)
        await #expect(throws: PMTilesError.unsupportedVersion(4)) { try await future.readHeader() }

        // répertoire gzip annoncé brotli, puis annoncé sans compression : dans les deux cas, refus
        for compression: UInt8 in [1, 3, 4] {
            var altered = original
            altered[Field.internalCompression] = compression
            let reader = makeReader(altered)
            await #expect(throws: PMTilesError.self) {
                try await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y)
            }
        }
        // tuiles PNG annoncées gzip : l'en-tête gzip manque
        var tiles = original
        tiles[Field.tileCompression] = 2
        let gzipped = makeReader(tiles)
        await #expect(throws: PMTilesError.self) {
            try await gzipped.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y)
        }
    }

    @Test("Zooms aberrants dans l'en-tête : une tuile hors de 64 bits est absente, pas un arrêt")
    func zooms() async throws {
        var data = try fixtureData()
        data[Field.minZoom] = 0
        data[Field.maxZoom] = 255
        let reader = makeReader(data)
        #expect(try await reader.tile(z: 40, x: 0, y: 0) == nil)
        #expect(try await reader.tile(z: 255, x: 1, y: 1) == nil)
        #expect(try await reader.tile(z: -1, x: 0, y: 0) == nil)
        #expect(try await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y) != nil)
    }

    @Test("Fichier tronqué : dans l'en-tête, dans le répertoire, dans une tuile", arguments: [0, 50, 126, 127, 150, 171, 232, 1_000, 70_000])
    func truncated(count: Int) async throws {
        let data = try fixtureData().prefix(count)
        let reader = makeReader(Data(data))
        await #expect(throws: PMTilesError.self) {
            try await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y)
        }
    }

    @Test("Fichier tronqué lu sur disque (LocalFileSource)")
    func truncatedOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "champis-pmtiles-\(UUID().uuidString).pmtiles")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixtureData().prefix(1_000).write(to: url)
        let reader = PMTilesReader(source: try LocalFileSource(url: url))
        await #expect(throws: PMTilesError.self) {
            try await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y)
        }
    }

    @Test("Répertoire racine dont le flux gzip est écrasé")
    func corruptGzip() async throws {
        var data = try fixtureData()
        // racine : 45 octets à partir de 127 ; 10 d'en-tête gzip, 8 de fin, le flux DEFLATE entre les deux
        for i in (127 + 10)..<(127 + 45 - 8) {
            data[i] = 0
        }
        let reader = makeReader(data)
        await #expect(throws: PMTilesError.self) { try await reader.rootDirectory() }
    }

    @Test("Chaque octet de l'en-tête et du répertoire muté : erreur ou résultat, jamais d'arrêt")
    func everyByte() async throws {
        let original = try fixtureData()
        // en-tête (hors signature), répertoire racine et métadonnées : octets 8 à 231
        for position in 8..<232 {
            for value in [UInt8(0x00), 0x7F, 0x80, 0xFF] where original[position] != value {
                var data = original
                data[position] = value
                let reader = makeReader(data)
                _ = try? await reader.metadata()
                for z in [0, 6, 7, 15, 31] {
                    _ = try? await reader.tile(z: z, x: (1 << z) / 2, y: (1 << z) / 3)
                }
                if let tile = try? await reader.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y) {
                    _ = try? PNGDecoder.decode(tile, side: PNGDecoder.tileSide)
                }
            }
        }
    }
}

struct MalformedDirectoryTests {
    @Test("Nombre d'entrées plus grand que ce que le tampon peut contenir")
    func announcedCount() {
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(Varint.encode(UInt64.max))) }
        var million = Varint.encode(1_000_000)
        million += [1, 1, 1]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(million)) }
        // deux entrées annoncées, la place d'une seule
        let two: [UInt8] = [2, 1, 1, 1, 1, 1, 1, 1]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(two)) }
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data()) }
    }

    @Test("Identifiant, série, longueur ou décalage qui déborde")
    func overflows() {
        // deux identifiants dont la somme dépasse 64 bits
        var ids = Varint.encode(2)
        ids += Varint.encode(UInt64.max)
        ids += [1, 1, 1, 1, 1, 1, 0]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(ids)) }
        // longueur de série hors de 32 bits
        var run: [UInt8] = [1, 1]
        run += Varint.encode(UInt64(1) << 32)
        run += [1, 1]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(run)) }
        // longueur hors de 32 bits
        var length: [UInt8] = [1, 1, 1]
        length += Varint.encode(UInt64(1) << 40)
        length += [1]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(length)) }
        // seconde entrée contiguë à une première placée en fin de 64 bits
        var offset: [UInt8] = [2, 1, 1, 1, 1, 5, 5]
        offset += Varint.encode(UInt64.max)
        offset += [0]
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(offset)) }
        // entier variable de plus de 64 bits
        let endless = [UInt8](repeating: 0xFF, count: 12)
        #expect(throws: PMTilesError.self) { try Directory.deserialize(Data(endless)) }
    }

    @Test("Répertoire tronqué à chaque longueur")
    func truncated() throws {
        let entries = [
            DirectoryEntry(tileID: 5, offset: 0, length: 100, runLength: 1),
            DirectoryEntry(tileID: 300, offset: 100, length: 70_000, runLength: 3),
            DirectoryEntry(tileID: 20_000, offset: 1 << 33, length: 10, runLength: 0),
        ]
        let whole = Directory.serialize(entries)
        #expect(try Directory.deserialize(whole) == entries)
        for count in 0..<whole.count {
            #expect(throws: PMTilesError.self, "\(count) octets") {
                try Directory.deserialize(Data(whole.prefix(count)))
            }
        }
    }

    @Test("Recherche dans des entrées non triées : pas de débordement")
    func unsorted() {
        let entries = [
            DirectoryEntry(tileID: 900, offset: 0, length: 1, runLength: 2),
            DirectoryEntry(tileID: 10, offset: 1, length: 1, runLength: 2),
        ]
        for id: UInt64 in [0, 5, 10, 11, 12, 899, 900, 901, 902, UInt64.max] {
            _ = Directory.find(entries, tileID: id)
        }
        #expect(Directory.find(entries, tileID: 5) == nil)
    }
}

struct BoundedInflateTests {
    /// 100 000 zéros, compressés par gzip (132 octets) et par zlib (120 octets).
    static let gzipZeros = "H4sIAAAAAAAC/+3BMQEAAADCoPVPbQ0PoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIBXA32VEdSghgEA"
    static let zlibZeros = "eNrtwTEBAAAAwqD1T20ND6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAVwOGrwAB"
    /// 65 792 zéros en zlib : les lignes filtrées d'une image grise 256 × 256 toute noire.
    static let zlibTile = "eNrtwQEBAAAAgJD+r+4ICgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgBDwAB"

    @Test("La sortie de la décompression est bornée par l'appelant, pas par le flux")
    func limit() throws {
        let gzip = try #require(Data(base64Encoded: Self.gzipZeros))
        #expect(try Inflate.gunzip(gzip, limit: 100_000).count == 100_000)
        #expect(try Inflate.gunzip(gzip, limit: 1 << 20) == Data(count: 100_000))
        #expect(throws: PMTilesError.self) { try Inflate.gunzip(gzip, limit: 99_999) }
        #expect(throws: PMTilesError.self) { try Inflate.gunzip(gzip, limit: 1_000) }
        #expect(throws: PMTilesError.self) { try Inflate.gunzip(gzip, limit: 0) }
        // flux interrompu : une erreur, pas une boucle
        #expect(throws: PMTilesError.self) { try Inflate.gunzip(Data(gzip.prefix(60)) + Data(count: 8), limit: 1 << 20) }
        #expect(throws: PMTilesError.self) { try Inflate.decompress(Data(count: 10), .none, limit: 9) }
        #expect(try Inflate.decompress(Data(count: 10), .none, limit: 10).count == 10)
    }

    /// PNG gris 8 bits aux dimensions données, dont l'IDAT est `idat` (CRC à zéro : non vérifié).
    static func png(width: UInt32, height: UInt32, idat: Data) -> Data {
        func be(_ v: UInt32) -> [UInt8] {
            [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        let crc = [UInt8](repeating: 0, count: 4)
        var out: [UInt8] = PNGDecoder.signature
        out += be(13)
        out += Array("IHDR".utf8)
        out += be(width)
        out += be(height)
        out += [8, 0, 0, 0, 0]
        out += crc
        out += be(UInt32(idat.count))
        out += Array("IDAT".utf8)
        out += [UInt8](idat)
        out += crc
        out += be(0)
        out += Array("IEND".utf8)
        out += crc
        return Data(out)
    }

    @Test("PNG : dimensions refusées dès l'IHDR, flux plus long que l'image refusé")
    func pngLimits() throws {
        let tile = try #require(Data(base64Encoded: Self.zlibTile))
        let bomb = try #require(Data(base64Encoded: Self.zlibZeros))

        // témoin : une tuile 256 × 256 toute noire se décode
        let decoded = try PNGDecoder.decode(Self.png(width: 256, height: 256, idat: tile), side: PNGDecoder.tileSide)
        #expect(decoded.width == 256 && decoded.height == 256 && decoded.channels == 1)
        #expect(decoded.data.count == 256 * 256 && decoded.data.allSatisfy { $0 == 0 })

        // dimensions aberrantes : refus avant d'allouer quoi que ce soit
        for (width, height) in [(UInt32.max, UInt32.max), (0x7FFF_FFFF, 1), (1, 0x7FFF_FFFF), (0, 256), (256, 0), (1025, 16)] as [(UInt32, UInt32)] {
            #expect(throws: PNGError.self, "\(width) × \(height)") {
                try PNGDecoder.decode(Self.png(width: width, height: height, idat: tile))
            }
        }
        // une tuile doit faire 256 × 256
        for (width, height) in [(255, 256), (256, 257), (512, 512), (24, 16)] as [(UInt32, UInt32)] {
            #expect(throws: PNGError.self, "\(width) × \(height)") {
                try PNGDecoder.decode(Self.png(width: width, height: height, idat: tile), side: PNGDecoder.tileSide)
            }
        }
        // flux qui se décompresse en plus que l'image annoncée
        #expect(throws: PNGError.self) {
            try PNGDecoder.decode(Self.png(width: 256, height: 256, idat: bomb), side: PNGDecoder.tileSide)
        }
        // flux plus court que l'image annoncée
        #expect(throws: PNGError.self) {
            try PNGDecoder.decode(Self.png(width: 256, height: 256, idat: Data(tile.prefix(40))), side: PNGDecoder.tileSide)
        }
        #expect(throws: PNGError.self) {
            try PNGDecoder.decode(Self.png(width: 1024, height: 1024, idat: tile))
        }
        // IDAT avant l'en-tête
        var headless: [UInt8] = PNGDecoder.signature
        headless += [0, 0, 0, 4]
        headless += Array("IDAT".utf8)
        headless += [UInt8](repeating: 0, count: 8)
        #expect(throws: PNGError.missingHeader) { try PNGDecoder.decode(Data(headless)) }
    }

    @Test("PNG d'une vraie tuile tronqué ou muté : erreur ou image, jamais d'arrêt")
    func mutatedTile() async throws {
        let source = makeReader(try fixtureData())
        let png = try #require(try await source.tile(z: firstTile.z, x: firstTile.x, y: firstTile.y))
        #expect(try PNGDecoder.decode(png, side: PNGDecoder.tileSide).width == 256)
        for count in [0, 7, 8, 20, 33, 40, png.count / 2] {
            #expect(throws: PNGError.self, "\(count) octets") {
                try PNGDecoder.decode(Data(png.prefix(count)), side: PNGDecoder.tileSide)
            }
        }
        // les 64 premiers octets (signature, IHDR, début de l'IDAT) et un octet sur 2 999 ensuite
        var positions = Array(0..<64)
        positions += Array(stride(from: 64, to: png.count, by: 2_999))
        for position in positions {
            for value in [UInt8(0x00), 0x80, 0xFF] where png[position] != value {
                var data = png
                data[position] = value
                _ = try? PNGDecoder.decode(data, side: PNGDecoder.tileSide)
            }
        }
    }
}

/// Serveur factice qui ignore `Range` et renvoie toujours le fichier entier (200).
final class WholeFileURLProtocol: URLProtocol, @unchecked Sendable {
    static let body: Data = Bundle.module.url(forResource: "fixture.pmtiles", withExtension: nil)
        .flatMap { try? Data(contentsOf: $0) } ?? Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = WholeFileURLProtocol.body
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct RangeRequestTests {
    @Test("En-tête Range : pas de débordement, pas de plage vide")
    func header() {
        #expect(RemoteRangeSource.rangeHeader(offset: 0, length: 127) == "bytes=0-126")
        #expect(RemoteRangeSource.rangeHeader(offset: 232, length: 1) == "bytes=232-232")
        #expect(RemoteRangeSource.rangeHeader(offset: UInt64.max, length: 1) == "bytes=18446744073709551615-18446744073709551615")
        #expect(RemoteRangeSource.rangeHeader(offset: UInt64.max, length: 2) == nil)
        #expect(RemoteRangeSource.rangeHeader(offset: UInt64.max - 5, length: 100) == nil)
        #expect(RemoteRangeSource.rangeHeader(offset: 10, length: 0) == nil)
        #expect(RemoteRangeSource.rangeHeader(offset: 10, length: -3) == nil)
    }

    @Test("Serveur sans Range (200) : lu pour une plage du début d'un petit fichier, refusé au-delà")
    func wholeFile() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WholeFileURLProtocol.self]
        let source = RemoteRangeSource(
            url: URL(string: "https://tiles.example/T-fixture.pmtiles")!, session: URLSession(configuration: config)
        )
        let body = WholeFileURLProtocol.body
        #expect(body.count > 1_000)
        #expect(try await source.read(offset: 0, length: 127) == body.prefix(127))
        #expect(try await source.read(offset: 232, length: 500) == body.subdata(in: 232..<732))
        #expect(try await source.read(offset: 5, length: 0) == Data())
        // plage au-delà de la petite taille admise : refus, sans charger le corps
        await #expect(throws: PMTilesError.rangeUnavailable(200)) {
            try await source.read(offset: UInt64(RemoteRangeSource.maxWholeResponseBytes), length: 10)
        }
        await #expect(throws: PMTilesError.rangeUnavailable(200)) {
            try await source.read(offset: UInt64.max - 100, length: 10)
        }
        // plage qui dépasse la fin du fichier annoncé
        await #expect(throws: PMTilesError.self) {
            try await source.read(offset: UInt64(body.count) - 5, length: 10)
        }
        // plage qui dépasse 64 bits : pas de requête
        await #expect(throws: PMTilesError.self) {
            try await source.read(offset: UInt64.max, length: 10)
        }
    }
}
