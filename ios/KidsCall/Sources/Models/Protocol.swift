import Foundation

// MARK: - Shared data types (mirrors server/src/server.js)

struct Member: Codable, Identifiable, Equatable, Hashable {
    let deviceId: String
    let name: String
    let isOwner: Bool
    var id: String { deviceId }
}

struct Participant: Codable, Identifiable, Equatable {
    let deviceId: String
    let name: String
    let seq: Int
    var id: String { deviceId }
}

struct CallState: Codable, Equatable {
    var callId: String?
    var participants: [Participant]

    static let idle = CallState(callId: nil, participants: [])
}

struct IceServerInfo: Codable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct GroupInfo: Codable, Equatable {
    let name: String
    let maxMembers: Int?
}

struct Welcome: Codable {
    let selfMember: Member
    let group: GroupInfo
    let members: [Member]
    let call: CallState
    let iceServers: [IceServerInfo]

    enum CodingKeys: String, CodingKey {
        case selfMember = "self"
        case group, members, call, iceServers
    }
}

/// SDP or ICE candidate relayed between two call participants.
struct SignalPayload: Codable, Equatable {
    var type: String            // "offer" | "answer" | "candidate"
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

struct Invite: Equatable {
    let token: String
    let url: String
    let expiresAt: Date

    /// Token grouped as XXXX-XXXX-XXXX-XXXX for reading aloud / typing.
    var displayToken: String {
        stride(from: 0, to: token.count, by: 4).map { i -> String in
            let start = token.index(token.startIndex, offsetBy: i)
            let end = token.index(start, offsetBy: min(4, token.count - i))
            return String(token[start..<end])
        }.joined(separator: "-")
    }
}

// MARK: - Server -> client messages

enum ServerMessage {
    case challenge(nonce: String)
    case welcome(Welcome)
    case membersUpdated([Member])
    case callState(CallState)
    case signal(from: String, payload: SignalPayload)
    case inviteCreated(Invite)
    case inviteRevoked
    case pushRegistered
    case pong
    case error(code: String, inReplyTo: String?)
    case unknown(type: String)

    static func decode(_ data: Data) throws -> ServerMessage {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "challenge":
            return .challenge(nonce: try decoder.decode(ChallengeBody.self, from: data).nonce)
        case "welcome":
            return .welcome(try decoder.decode(Welcome.self, from: data))
        case "members.updated":
            return .membersUpdated(try decoder.decode(MembersBody.self, from: data).members)
        case "call.state":
            return .callState(try decoder.decode(CallState.self, from: data))
        case "signal":
            let m = try decoder.decode(SignalBody.self, from: data)
            return .signal(from: m.from, payload: m.payload)
        case "invite.created":
            let m = try decoder.decode(InviteBody.self, from: data)
            return .inviteCreated(Invite(token: m.token, url: m.url, expiresAt: Date(timeIntervalSince1970: m.expiresAt / 1000)))
        case "invite.revoked":
            return .inviteRevoked
        case "push.registered":
            return .pushRegistered
        case "pong":
            return .pong
        case "error":
            let m = try decoder.decode(ErrorBody.self, from: data)
            return .error(code: m.code, inReplyTo: m.inReplyTo)
        default:
            return .unknown(type: envelope.type)
        }
    }
}

private struct Envelope: Decodable { let type: String }
private struct ChallengeBody: Decodable { let nonce: String }
private struct MembersBody: Decodable { let members: [Member] }
private struct SignalBody: Decodable { let from: String; let payload: SignalPayload }
private struct InviteBody: Decodable { let token: String; let url: String; let expiresAt: Double }
private struct ErrorBody: Decodable { let code: String; let inReplyTo: String? }

// MARK: - Client -> server messages

enum ClientMessage {
    case auth(publicKey: String, signature: String)
    case ping
    case pushRegister(voipToken: String)
    case inviteCreate
    case inviteRevoke
    case memberRemove(deviceId: String)
    case callJoin
    case callLeave
    case signal(to: String, payload: SignalPayload)

    func encode() throws -> Data {
        var dict: [String: Any]
        switch self {
        case let .auth(publicKey, signature):
            dict = ["type": "auth", "publicKey": publicKey, "signature": signature]
        case .ping:
            dict = ["type": "ping"]
        case let .pushRegister(voipToken):
            dict = ["type": "push.register", "voipToken": voipToken]
        case .inviteCreate:
            dict = ["type": "invite.create"]
        case .inviteRevoke:
            dict = ["type": "invite.revoke"]
        case let .memberRemove(deviceId):
            dict = ["type": "member.remove", "deviceId": deviceId]
        case .callJoin:
            dict = ["type": "call.join"]
        case .callLeave:
            dict = ["type": "call.leave"]
        case let .signal(to, payload):
            let payloadData = try JSONEncoder().encode(payload)
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            dict = ["type": "signal", "to": to, "payload": payloadObject]
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Human readable error codes (Japanese UI)

enum ErrorText {
    static func forCode(_ code: String) -> String {
        switch code {
        case "invalid_setup_token": return "セットアップ用の合言葉が違います。"
        case "setup_disabled": return "このサーバーではグループの新規作成が無効になっています。"
        case "group_exists": return "このサーバーにはすでにグループがあります。招待で参加してください。"
        case "no_group": return "このサーバーにはまだグループがありません。"
        case "invalid_invite": return "招待が無効か、期限切れです。新しい招待をもらってください。"
        case "group_full": return "グループは5台までです。これ以上は追加できません。"
        case "already_member": return "この端末はすでに登録されています。"
        case "forbidden": return "この操作は管理者だけができます。"
        case "invalid_name": return "名前は1〜20文字で入力してください。"
        case "rate_limited": return "操作が多すぎます。少し待ってからやり直してください。"
        case "unauthorized": return "この端末はグループに登録されていません。"
        case "removed": return "この端末はグループから外されました。"
        case "call_full": return "通話は5台までです。"
        case "not_in_call": return "通話に参加していません。"
        default: return "エラーが発生しました（\(code)）"
        }
    }
}
