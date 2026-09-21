import Foundation

/// What the app hands the widget after every scan: four numbers and when
/// they were true. The widget runs sandboxed in its own process and cannot
/// scan anything itself, so this file in the shared app group is all it
/// knows.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var systemDataBytes: Int64
    public var freeBytes: Int64
    public var safeBytes: Int64
    public var capacityBytes: Int64
    public var scannedAt: Date

    public init(systemDataBytes: Int64, freeBytes: Int64, safeBytes: Int64, capacityBytes: Int64, scannedAt: Date) {
        self.systemDataBytes = systemDataBytes
        self.freeBytes = freeBytes
        self.safeBytes = safeBytes
        self.capacityBytes = capacityBytes
        self.scannedAt = scannedAt
    }

    /// Team-prefixed, which is what lets a Developer ID app and its widget
    /// share a container without a provisioning profile.
    public static let appGroup = "6NK6D7LL79.local.sysdata"
    public static let widgetKind = "SystemDataWidget"

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "snapshot.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
