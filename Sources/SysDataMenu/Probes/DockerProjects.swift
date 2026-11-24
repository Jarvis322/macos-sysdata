import Foundation

/// What each Docker Compose project costs, traced back to its folder so the
/// Projects view can put it next to that project's node_modules and
/// DerivedData.
///
/// Compose labels every container with the folder it was started from, which
/// is the only link from Docker's world back to a project on disk. Images and
/// volumes are reached through those containers, which also keeps the rows
/// here apart from the Docker category's prune rows: an image no container
/// uses and a volume nothing is attached to are already counted there, as
/// reclaimable, and counting them again would inflate every total.
///
/// Sizes come from the Engine API rather than `docker system df`, because
/// only the API gives each image's shared size as a number. Images share
/// layers — every Node project's image starts from the same base — so an
/// image is sized by what only it holds: the part deleting it would free.
enum DockerProjects {
    static let workingDirLabel = "com.docker.compose.project.working_dir"
    static let projectLabel = "com.docker.compose.project"

    /// The parts of a `GET /system/df?verbose=1` response this reads. API
    /// 1.52 moved the lists under `ImagesUsage.Items` and friends, and 1.53
    /// dropped the old top-level `Images`, `Containers` and `Volumes`; both
    /// shapes are read, so neither an old daemon nor a new one is missed.
    struct Usage: Decodable {
        var images: [Image] = []
        var containers: [Container] = []
        var volumes: [Volume] = []

        struct Image: Decodable {
            let Id: String
            let RepoTags: [String]?
            let Size: Int64
            let SharedSize: Int64
            let Created: Int64?

            /// What deleting it frees. `SharedSize` is -1 when the daemon did
            /// not compute it, and then nothing is claimed rather than the
            /// full size, which would count shared layers once per image.
            var uniqueSize: Int64 { SharedSize >= 0 ? max(Size - SharedSize, 0) : 0 }
        }

        struct Container: Decodable {
            let Id: String
            let ImageID: String?
            let Labels: [String: String]?
            /// `running`, `exited`, `paused`... Absent from older fixtures.
            let State: String?

            /// A container that is up, or about to be: it holds its image
            /// and its data, and removing it would stop someone's work.
            var isActive: Bool { ["running", "paused", "restarting"].contains(State ?? "") }
        }

        struct Volume: Decodable {
            let Name: String
            let Labels: [String: String]?
            let UsageData: UsageData?

            struct UsageData: Decodable {
                let Size: Int64
                let RefCount: Int64
            }
        }

        private struct List<Item: Decodable>: Decodable {
            let Items: [Item]?
        }

        private enum Keys: String, CodingKey {
            case Images, Containers, Volumes
            case ImagesUsage, ContainersUsage, VolumesUsage
            // The API reference spells these in the singular.
            case ImageUsage, ContainerUsage, VolumeUsage
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func list<T: Decodable>(_ legacy: Keys, _ current: [Keys]) throws -> [T] {
                for key in current {
                    if let items = try c.decodeIfPresent(List<T>.self, forKey: key)?.Items { return items }
                }
                return try c.decodeIfPresent([T].self, forKey: legacy) ?? []
            }
            images = try list(.Images, [.ImagesUsage, .ImageUsage])
            containers = try list(.Containers, [.ContainersUsage, .ContainerUsage])
            volumes = try list(.Volumes, [.VolumesUsage, .VolumeUsage])
        }
    }

    /// Asks the daemon the CLI is pointed at, over its socket, at the API
    /// version the daemon itself reports. Nil when any step fails: no Docker,
    /// not running, a remote context, or an answer that does not parse.
    static func usage(docker: String) async -> Usage? {
        guard let host = try? await Shell.run(
                  docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                  mergeStderr: false, timeout: Shell.probeTimeout),
              host.succeeded,
              let socket = socketPath(fromHost: host.output),
              let version = try? await Shell.run(
                  docker, ["version", "--format", "{{.Server.APIVersion}}"],
                  mergeStderr: false, timeout: Shell.probeTimeout),
              version.succeeded
        else { return nil }
        let api = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard api.allSatisfy({ $0.isNumber || $0 == "." }), !api.isEmpty,
              let df = try? await Shell.run(
                  "/usr/bin/curl",
                  ["--silent", "--fail", "--max-time", "60", "--unix-socket", socket,
                   "http://localhost/v\(api)/system/df?verbose=1"],
                  mergeStderr: false, timeout: .seconds(70)),
              df.succeeded
        else { return nil }
        return try? JSONDecoder().decode(Usage.self, from: Data(df.output.utf8))
    }

    /// `unix:///Users/me/.docker/run/docker.sock` → its path. A TCP or SSH
    /// context points at another machine, whose disk is not this one's.
    static func socketPath(fromHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("unix://") else { return nil }
        let path = String(trimmed.dropFirst("unix://".count))
        return path.isEmpty ? nil : path
    }

    /// One row per Compose project for its images, and one for its volumes.
    ///
    /// An image counts toward a project only when every container using it
    /// is that project's: a postgres image two projects run belongs to
    /// neither, and removing it for one would break the other.
    static func items(
        from usage: Usage, docker: String, now: Date = .now, engineData: [URL] = [],
        projectRoot: (URL) -> URL = { ProjectProbe.projectRoot(of: $0) }
    ) -> [StorageItem] {
        struct Compose {
            var folder: URL
            var containerIDs: [String] = []
            var activeCount = 0
        }
        var projects: [String: Compose] = [:]
        var projectsUsingImage: [String: Set<String>] = [:]
        for container in usage.containers {
            let labels = container.Labels ?? [:]
            let project = labels[projectLabel]
            if let image = container.ImageID {
                projectsUsingImage[image, default: []].insert(project ?? "")
            }
            guard let project, let dir = labels[workingDirLabel], dir.hasPrefix("/") else { continue }
            projects[project, default: Compose(folder: URL(fileURLWithPath: dir))].containerIDs.append(container.Id)
            if container.isActive { projects[project]?.activeCount += 1 }
        }

        var items: [StorageItem] = []
        for (name, compose) in projects.sorted(by: { $0.key < $1.key }) {
            let root = compose.folder.exists ? projectRoot(compose.folder) : compose.folder
            let images = usage.images.filter { projectsUsingImage[$0.Id] == [name] }
            let imageBytes = images.reduce(0) { $0 + $1.uniqueSize }
            if imageBytes > 0 {
                // A tag is removed by name; an image with several tags cannot
                // be removed by ID without forcing, and one with none can.
                let references = images.flatMap { image -> [String] in
                    let tags = (image.RepoTags ?? []).filter { $0 != "<none>:<none>" }
                    return tags.isEmpty ? [image.Id] : tags
                }
                let created = images.compactMap(\.Created).max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
                // Containers that are up are never removed from here. Their
                // images are in use and could not go anyway, and removing a
                // running container would stop someone's database mid-work.
                let isRunning = compose.activeCount > 0
                items.append(StorageItem(
                    id: "docker-project-images-\(name)", category: .docker,
                    name: "Docker images: \(name)",
                    detail: isRunning
                        ? "\(compose.folder.abbreviatedPath). \(compose.activeCount) of its containers are running, so its images are in use."
                        : "\(compose.folder.abbreviatedPath). Its containers and the images only they use; "
                            + "volumes are kept. docker compose up builds or pulls them again.",
                    sizeBytes: imageBytes, safety: isRunning ? .manual : .review,
                    action: isRunning
                        ? .manual("Stop the project first, keeping its volumes:\ndocker compose -p \(name) down")
                        : .steps([
                            .command(executable: docker, arguments: ["container", "rm"] + compose.containerIDs),
                            .command(executable: docker, arguments: ["image", "rm"] + references),
                        ]),
                    revealURL: compose.folder, alsoClaims: engineData, project: root, builtAt: created
                ))
            }

            let volumes = usage.volumes.filter {
                $0.Labels?[projectLabel] == name && ($0.UsageData?.RefCount ?? 0) > 0
            }
            let volumeBytes = volumes.reduce(0) { $0 + max($1.UsageData?.Size ?? 0, 0) }
            if volumeBytes > 0 {
                items.append(StorageItem(
                    id: "docker-project-volumes-\(name)", category: .docker,
                    name: "Docker volumes: \(name)",
                    detail: "\(compose.folder.abbreviatedPath). Data its containers keep, often a database. Not archived.",
                    sizeBytes: volumeBytes, safety: .manual,
                    action: .manual("Once nothing in it is needed:\ndocker compose -p \(name) down --volumes"),
                    revealURL: compose.folder, alsoClaims: engineData, project: root
                ))
            }
        }
        return items
    }
}
