import Foundation

struct PoolWidgetSnapshot: Codable {
    static let group = "group.com.fgotrack.house"
    var balance: Int64 = 0
    var spent: Int64 = 0
    var pending: Int = 0
    var month: String = ""
    var updated: Date = .distantPast
    static var file: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("pool-widget.json") }
    static func read() -> Self {
        guard let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func write() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
