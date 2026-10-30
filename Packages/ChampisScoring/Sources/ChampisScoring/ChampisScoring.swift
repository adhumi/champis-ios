/// Portage Swift du scoring Champis (trapèze, Φ, M, M_eff, groupes, palette).
///
/// Implémentation de référence : `api/champis_api/scoring.py` et `pipeline/champis_pipeline/scoring.py`
/// du monorepo (skills `champis-model`, `scoring-parity`). Même ordre d'opérations que Python, `Double`
/// partout, dates civiles sans fuseau. Le contrat est `shared/vectors/`, rejoué par les tests ;
/// aucune valeur d'espèce ne vit ici : les paramètres viennent de `/species`.
public enum ChampisScoring {
    /// Version du modèle que ce portage sait calculer. L'app refuse une `scoring_version`
    /// différente renvoyée par `/species` plutôt que d'afficher un score faux.
    public static let supportedScoringVersion = "1.0.0"

    /// Score d'un pixel : `S = T × M_eff × Φ`.
    public static func score(t: Double, mEff: Double, phi: Double) -> Double {
        t * mEff * phi
    }
}

/// Une série trop courte, une date hors série, un paramètre absent : jamais une approximation.
public enum ScoringError: Error, Equatable, Sendable {
    case dateOutOfSeries(CivilDate)
    case seriesTooShort(requested: Int, available: Int, end: CivilDate)
    case nonContiguousSeries(CivilDate, CivilDate)
    case lengthMismatch(String, Int, Int)
    case invalidDate(String)
}
