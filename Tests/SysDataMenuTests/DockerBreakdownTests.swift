import Foundation
import Testing

@testable import SysDataMenu

/// One Docker row used to promise everything `docker system df` calls
/// reclaimable while running `docker system prune -f`, which frees only the
/// dangling part. Each kind now has its own row, sized at what its own
/// command frees.
struct DockerBreakdownTests {
    /// The shape Docker prints, one object per line.
    private let output = """
    {"Active":"2","Reclaimable":"1.211GB (45%)","Size":"2.7GB","TotalCount":"10","Type":"Images"}
    {"Active":"1","Reclaimable":"0B (0%)","Size":"12.3kB","TotalCount":"3","Type":"Containers"}
    {"Active":"1","Reclaimable":"250MB (40%)","Size":"600MB","TotalCount":"4","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"3.1GB","Size":"3.1GB","TotalCount":"56","Type":"Build Cache"}
    """

    @Test func eachKindIsReadOnItsOwn() {
        let sizes = DockerProbe.reclaimableByType(output)
        #expect(sizes["Images"] == 1_211_000_000)
        #expect(sizes["Containers"] == 0)
        #expect(sizes["Local Volumes"] == 250_000_000)
        #expect(sizes["Build Cache"] == 3_100_000_000)
    }

    @Test func aKindWithNothingToFreeGetsNoRow() {
        let items = DockerProbe.items(fromSystemDF: output, docker: "/usr/local/bin/docker", reveal: nil)
        #expect(Set(items.map(\.id)) == ["docker-images", "docker-volumes", "docker-build-cache"])
    }

    /// Each row runs the command that frees what it says, and only volumes —
    /// where databases keep their data — carry that warning.
    @Test func eachRowRunsItsOwnPrune() {
        let items = Dictionary(uniqueKeysWithValues: DockerProbe.items(
            fromSystemDF: output, docker: "/usr/local/bin/docker", reveal: nil
        ).map { ($0.id, $0) })

        #expect(items["docker-build-cache"]?.safety == .safe)
        #expect(items["docker-images"]?.safety == .review)
        #expect(items["docker-volumes"]?.safety == .review)
        #expect(items["docker-volumes"]?.detail.contains("Databases") == true)
        if case .command(_, let arguments) = items["docker-images"]?.action {
            #expect(arguments == ["image", "prune", "-a", "-f"])
        } else {
            Issue.record("images should prune with docker image prune -a")
        }
    }

    @Test func lowerCaseKilobytesAreRead() {
        #expect(DockerProbe.parseDockerSize("12.3kB") == 12_300)
    }
}
