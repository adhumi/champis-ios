import Foundation
import Testing
@testable import ChampisScoring

/// En-tête commun aux sept fichiers de vecteurs (`shared/vectors/*.json`).
private struct VectorFile: Decodable {
    struct GeneratedBy: Decodable {
        let scoringVersion: String
        let speciesHash: String

        enum CodingKeys: String, CodingKey {
            case scoringVersion = "scoring_version"
            case speciesHash = "species_hash"
        }
    }

    let generatedBy: GeneratedBy

    enum CodingKeys: String, CodingKey {
        case generatedBy = "generated_by"
    }
}

private let vectorNames = ["trapezoid", "phi", "m", "group", "palette", "interp", "alt"]

private func loadVector(_ name: String) throws -> VectorFile {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "vectors"),
        "vecteur \(name).json absent : lancer scripts/sync-vectors.sh"
    )
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
}

struct VectorsTests {
    @Test("Les sept fichiers de vecteurs sont présents et lisibles", arguments: vectorNames)
    func vecteurPresent(name: String) throws {
        let file = try loadVector(name)
        #expect(!file.generatedBy.speciesHash.isEmpty)
    }

    @Test("Les vecteurs ont été générés pour la version de scoring que ce portage sait calculer")
    func versionDuScoring() throws {
        for name in vectorNames {
            let file = try loadVector(name)
            #expect(file.generatedBy.scoringVersion == ChampisScoring.supportedScoringVersion, "\(name).json")
        }
    }

    @Test("Les sept fichiers viennent de la même génération")
    func memeGeneration() throws {
        let hashes = try Set(vectorNames.map { try loadVector($0).generatedBy.speciesHash })
        #expect(hashes.count == 1)
    }
}
