/// Portage Swift du scoring Champis (trapèze, M, Φ, M_eff, groupes, palette).
///
/// Le contrat est `shared/vectors/` du monorepo, copié dans les ressources de test par
/// `scripts/sync-vectors.sh` (skill `scoring-parity`). Aucune valeur d'espèce ne vit ici :
/// les paramètres viennent de `/species`. Le portage lui-même arrive dans une PR dédiée.
public enum ChampisScoring {
    /// Version du modèle que ce portage sait calculer.
    ///
    /// L'app refuse une `scoring_version` différente renvoyée par `/species` plutôt que
    /// d'afficher un score faux.
    public static let supportedScoringVersion = "1.0.0"
}
