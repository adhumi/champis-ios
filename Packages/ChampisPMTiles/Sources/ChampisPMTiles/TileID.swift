/// Identifiant de tuile PMTiles : position sur la courbe de Hilbert de chaque niveau, les niveaux
/// mis bout à bout (`zxy_to_tileid` / `tileid_to_zxy` de la spécification).
public enum TileID {
    public static func fromZXY(z: Int, x: Int, y: Int) -> UInt64 {
        precondition(z <= 31, "zoom > 31 dépasse 64 bits")
        precondition(x >= 0 && y >= 0 && x < (1 << z) && y < (1 << z), "x/y hors du niveau")
        var acc: UInt64 = ((UInt64(1) << UInt64(z * 2)) - 1) / 3
        var x = UInt64(x)
        var y = UInt64(y)
        var a = z - 1
        while a >= 0 {
            let s = UInt64(1) << UInt64(a)
            let rx = s & x
            let ry = s & y
            acc += ((3 * rx) ^ ry) << UInt64(a)
            (x, y) = rotate(s, x, y, rx, ry)
            a -= 1
        }
        return acc
    }

    public static func toZXY(_ tileID: UInt64) -> (z: Int, x: Int, y: Int) {
        let z = ((3 * tileID + 1).bitLength - 1) / 2
        precondition(z < 32)
        let acc: UInt64 = ((UInt64(1) << UInt64(z * 2)) - 1) / 3
        var pos = tileID - acc
        var x: UInt64 = 0
        var y: UInt64 = 0
        var s: UInt64 = 1
        let n = UInt64(1) << UInt64(z)
        while s < n {
            let rx = (pos / 2) & s
            let ry = (pos ^ rx) & s
            (x, y) = rotate(s, x, y, rx, ry)
            x += rx
            y += ry
            pos >>= 1
            s <<= 1
        }
        return (z, Int(x), Int(y))
    }

    static func rotate(_ n: UInt64, _ x: UInt64, _ y: UInt64, _ rx: UInt64, _ ry: UInt64) -> (UInt64, UInt64) {
        var x = x
        var y = y
        if ry == 0 {
            if rx != 0 {
                x = n - 1 - x
                y = n - 1 - y
            }
            swap(&x, &y)
        }
        return (x, y)
    }
}

extension UInt64 {
    /// Nombre de bits nécessaires, comme `int.bit_length()` en Python (0 pour 0).
    var bitLength: Int { UInt64.bitWidth - leadingZeroBitCount }
}
