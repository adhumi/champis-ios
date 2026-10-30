/// Gabarit trapézoïdal `min / opt_low / opt_high / max` : 0 hors `[min, max]`, 1 dans
/// `[opt_low, opt_high]`, linéaire entre. La seule fonction trapèze du client (règle 1 du modèle).
public struct Trapezoid: Codable, Hashable, Sendable {
    public let min: Double
    public let optLow: Double
    public let optHigh: Double
    public let max: Double

    public init(min: Double, optLow: Double, optHigh: Double, max: Double) {
        self.min = min
        self.optLow = optLow
        self.optHigh = optHigh
        self.max = max
    }

    /// Même découpage que `champis_pipeline.scoring.trapezoid` : plateau, rampe montante
    /// (`min ≤ x < opt_low`), rampe descendante (`opt_high < x ≤ max`). Une rampe de largeur nulle
    /// est une marche : `x == min` vaut 1.
    public func value(_ x: Double) -> Double {
        if x >= optLow && x <= optHigh { return 1.0 }
        if optLow > min, x >= min, x < optLow { return (x - min) / (optLow - min) }
        if max > optHigh, x > optHigh, x <= max { return (max - x) / (max - optHigh) }
        return 0.0
    }
}

/// Arrondi 0,5 → vers le haut, comme `round_half_up` (jamais l'arrondi au pair).
@inlinable
public func roundHalfUp(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}

/// Centre de la classe de 300 m contenant `altM` : 150, 450, 750… (0–299 → 150).
public func altitudeClass(_ altM: Double, classM: Double = 300) -> Double {
    (Swift.max(altM, 0.0) / classM).rounded(.down) * classM + classM / 2
}
