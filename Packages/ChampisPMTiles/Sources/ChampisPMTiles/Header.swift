import Foundation

public enum PMCompression: UInt8, Sendable {
    case unknown = 0
    case none = 1
    case gzip = 2
    case brotli = 3
    case zstd = 4
}

public enum PMTileType: UInt8, Sendable {
    case unknown = 0
    case mvt = 1
    case png = 2
    case jpeg = 3
    case webp = 4
    case avif = 5
}

/// Les 127 octets d'en-tête d'un fichier PMTiles v3.
public struct PMTilesHeader: Sendable, Equatable {
    public static let size = 127

    public let rootOffset: UInt64
    public let rootLength: UInt64
    public let metadataOffset: UInt64
    public let metadataLength: UInt64
    public let leafDirectoryOffset: UInt64
    public let leafDirectoryLength: UInt64
    public let tileDataOffset: UInt64
    public let tileDataLength: UInt64
    public let addressedTilesCount: UInt64
    public let tileEntriesCount: UInt64
    public let tileContentsCount: UInt64
    public let clustered: Bool
    public let internalCompression: PMCompression
    public let tileCompression: PMCompression
    public let tileType: PMTileType
    public let minZoom: Int
    public let maxZoom: Int
    public let minLonE7: Int32
    public let minLatE7: Int32
    public let maxLonE7: Int32
    public let maxLatE7: Int32
    public let centerZoom: Int
    public let centerLonE7: Int32
    public let centerLatE7: Int32

    public var bounds: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        (Double(minLonE7) / 1e7, Double(minLatE7) / 1e7, Double(maxLonE7) / 1e7, Double(maxLatE7) / 1e7)
    }

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= PMTilesHeader.size else { throw PMTilesError.truncated("en-tête") }
        guard String(decoding: bytes[0..<7], as: UTF8.self) == "PMTiles" else { throw PMTilesError.notPMTiles }
        guard bytes[7] == ChampisPMTiles.specVersion else { throw PMTilesError.unsupportedVersion(bytes[7]) }
        var r = ByteReader(bytes)
        try r.skip(8)
        rootOffset = try r.readUInt64LE()
        rootLength = try r.readUInt64LE()
        metadataOffset = try r.readUInt64LE()
        metadataLength = try r.readUInt64LE()
        leafDirectoryOffset = try r.readUInt64LE()
        leafDirectoryLength = try r.readUInt64LE()
        tileDataOffset = try r.readUInt64LE()
        tileDataLength = try r.readUInt64LE()
        addressedTilesCount = try r.readUInt64LE()
        tileEntriesCount = try r.readUInt64LE()
        tileContentsCount = try r.readUInt64LE()
        clustered = try r.readUInt8() == 1
        internalCompression = PMCompression(rawValue: try r.readUInt8()) ?? .unknown
        tileCompression = PMCompression(rawValue: try r.readUInt8()) ?? .unknown
        tileType = PMTileType(rawValue: try r.readUInt8()) ?? .unknown
        minZoom = Int(try r.readUInt8())
        maxZoom = Int(try r.readUInt8())
        minLonE7 = try r.readInt32LE()
        minLatE7 = try r.readInt32LE()
        maxLonE7 = try r.readInt32LE()
        maxLatE7 = try r.readInt32LE()
        centerZoom = Int(try r.readUInt8())
        centerLonE7 = try r.readInt32LE()
        centerLatE7 = try r.readInt32LE()
    }
}
