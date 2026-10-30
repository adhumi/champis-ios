import Testing
@testable import Champis

struct ChampisTests {
    @MainActor
    @Test func leModeleExposeLaVersionDuScoring() {
        let model = ContentModel()
        #expect(!model.scoringVersion.isEmpty)
    }
}
