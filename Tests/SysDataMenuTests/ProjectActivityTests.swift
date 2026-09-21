import Foundation
import Testing

@testable import SysDataMenu

/// A project's build folder is dated by the project, not by itself:
/// node_modules is as old as the last install, which says nothing about
/// whether anyone still works on the code beside it.
struct ProjectActivityTests {
    private let project: URL

    init() throws {
        project = URL.temporaryDirectory.appending(path: "project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    private func write(_ relative: String, daysAgo: Double) throws {
        let url = project.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path
        )
    }

    private func daysSince(_ date: Date?) -> Int? {
        date.flatMap { Calendar.current.dateComponents([.day], from: $0, to: .now).day }
    }

    /// The edit three folders down is what counts; a directory's own date
    /// would not have moved.
    @Test func aDeepEditKeepsTheProjectActive() throws {
        defer { try? FileManager.default.removeItem(at: project) }
        try write("package.json", daysAgo: 200)
        try write("src/components/ui/Button.tsx", daysAgo: 1)

        #expect(daysSince(ProjectProbe.lastActivity(in: project)) == 1)
    }

    /// A fresh install into an untouched project does not make it active.
    @Test func aFreshInstallDoesNotCountAsWork() throws {
        defer { try? FileManager.default.removeItem(at: project) }
        try write("src/index.ts", daysAgo: 120)
        try write("node_modules/react/index.js", daysAgo: 0)
        try write(".next/cache/build.json", daysAgo: 0)

        #expect(daysSince(ProjectProbe.lastActivity(in: project)) == 120)
    }

    @Test func aCommitCountsAsWork() throws {
        defer { try? FileManager.default.removeItem(at: project) }
        try write("src/index.ts", daysAgo: 120)
        try write(".git/index", daysAgo: 3)
        try write(".git/objects/ab/cdef", daysAgo: 0)

        #expect(daysSince(ProjectProbe.lastActivity(in: project)) == 3)
    }
}
