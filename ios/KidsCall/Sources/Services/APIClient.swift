import Foundation

struct RegistrationResponse: Decodable {
    let selfMember: Member
    let group: GroupInfo
    let members: [Member]

    enum CodingKeys: String, CodingKey {
        case selfMember = "self"
        case group, members
    }
}

private struct ChallengeResponse: Decodable { let nonce: String }
private struct APIErrorBody: Decodable { let error: String }

enum APIError: LocalizedError {
    case server(code: String, status: Int)
    case invalidResponse
    case network(Error)

    var errorDescription: String? {
        switch self {
        case let .server(code, _): return ErrorText.forCode(code)
        case .invalidResponse: return "サーバーからの応答が不正です。URLを確認してください。"
        case let .network(err): return "サーバーに接続できません。\(err.localizedDescription)"
        }
    }
}

/// HTTP client used only for the two registration flows. Everything else goes
/// over the authenticated WebSocket.
struct APIClient {
    let baseURL: URL
    let identity: DeviceIdentity

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func createGroup(setupToken: String, groupName: String, deviceName: String) async throws -> RegistrationResponse {
        let nonce = try await challenge()
        return try await post("/v1/group", body: [
            "setupToken": setupToken,
            "groupName": groupName,
            "deviceName": deviceName,
            "nonce": nonce,
            "publicKey": identity.publicKeyBase64,
            "signature": identity.registerSignature(nonce: nonce),
        ])
    }

    func join(inviteToken: String, deviceName: String) async throws -> RegistrationResponse {
        let nonce = try await challenge()
        return try await post("/v1/join", body: [
            "inviteToken": inviteToken,
            "deviceName": deviceName,
            "nonce": nonce,
            "publicKey": identity.publicKeyBase64,
            "signature": identity.registerSignature(nonce: nonce),
        ])
    }

    private func challenge() async throws -> String {
        let c: ChallengeResponse = try await post("/v1/challenge", body: [:])
        return c.nonce
    }

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.invalidResponse
            }
        }
        if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            throw APIError.server(code: err.error, status: http.statusCode)
        }
        throw APIError.server(code: "http_\(http.statusCode)", status: http.statusCode)
    }
}
