import Foundation
import Testing
@testable import SysDataMenu

/// Colima and OrbStack keep Docker's images in a VM disk the hidden-folder
/// scan also measures whole, so the same bytes were listed twice.
@Suite struct ContainerEngineOverlapTests {
    @Test func colimaAndOrbStackEndpointsNameTheirDataFolders() {
        let none: (String) -> String = { $0 }
        #expect(DockerProbe.engineData(forEndpoint: "unix:///Users/a/.colima/default/docker.sock\n", resolve: none)
            .map(\.path) == ["/Users/a/.colima/default", "/Users/a/.colima/_lima"])
        #expect(DockerProbe.engineData(forEndpoint: "unix:///Users/a/.orbstack/run/docker.sock", resolve: none)
            .map(\.path) == ["/Users/a/.orbstack/run", "/Users/a/.orbstack/data"])
        // The default socket, linked to OrbStack's.
        let linked: (String) -> String = { $0 == "/var/run/docker.sock" ? "/Users/a/.orbstack/run/docker.sock" : $0 }
        #expect(DockerProbe.engineData(forEndpoint: "unix:///var/run/docker.sock", resolve: linked)
            .map(\.path) == ["/Users/a/.orbstack/run", "/Users/a/.orbstack/data"])
        #expect(DockerProbe.engineData(forEndpoint: "unix:///Users/a/.docker/run/docker.sock", resolve: none).isEmpty)
        #expect(DockerProbe.engineData(forEndpoint: "tcp://10.0.0.2:2376", resolve: none).isEmpty)
    }

    @Test func theEngineFolderRowGivesWayToTheDockerRows() {
        let colima = URL(fileURLWithPath: "/tmp/sysdata-engine/.colima")
        let folderRow = StorageItem(
            id: "tool-.colima", category: .tools, name: "Colima virtual machine", detail: "VM disk.",
            sizeBytes: 60, safety: .review, action: .removePaths([colima]), revealURL: colima
        )
        let images = DockerProbe.items(
            fromSystemDF: #"{"Type":"Images","Reclaimable":"1.2GB (45%)"}"#, docker: "/usr/bin/docker",
            reveal: colima.appending(path: "default"), claims: [colima.appending(path: "default")]
        )
        #expect(!images.isEmpty)

        let kept = ProbeRegistry.withoutOverlaps([folderRow] + images).map(\.id)
        #expect(!kept.contains("tool-.colima"))
    }
}
