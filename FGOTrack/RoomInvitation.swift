import Foundation

/// Strictly accept our own app route or a legacy UUID, never an arbitrary website.
enum RoomInvitation {
    static func url(token: UUID) -> URL { URL(string: "fgotrack://invite/\(token.uuidString.lowercased())")! }
    static func token(from text: String) -> UUID? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: value) { return id }
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "fgotrack",
              parts.host?.lowercased() == "invite", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments[0].isEmpty else { return nil }
        return UUID(uuidString: String(segments[1]))
    }
}
