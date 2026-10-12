import Foundation

/// `kidscall://join?server=<https url>&token=<16 chars>` as encoded in the invite QR.
struct InviteLink: Equatable {
    let serverURL: URL
    let token: String

    static let scheme = "kidscall"
    private static let tokenAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value,
              let rawToken = items.first(where: { $0.name == "token" })?.value,
              let serverURL = URL(string: server),
              Self.isAcceptableServer(serverURL),
              let token = Self.normalizeToken(rawToken)
        else { return nil }
        self.serverURL = serverURL
        self.token = token
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func normalizeToken(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { tokenAlphabet.contains($0) }
        return cleaned.count == 16 ? cleaned : nil
    }

    /// Only HTTPS servers are accepted, except plain HTTP on the local network
    /// for development.
    static func isAcceptableServer(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}
