import Foundation
import SwiftUI

struct Registration: Codable, Equatable {
    var serverURL: URL
    var groupName: String
    var selfMember: Member
}

/// Root observable state: registration, group membership, connection and the call.
@MainActor
final class AppState: ObservableObject, SignalingClientDelegate {
    @Published private(set) var registration: Registration?
    @Published private(set) var members: [Member] = []
    @Published private(set) var callState: CallState = .idle
    @Published private(set) var connectionStatus: SignalingClient.Status = .disconnected
    @Published var invite: Invite?
    @Published var alertMessage: String?
    @Published var pendingInviteLink: InviteLink?

    let callManager: CallManager
    private let identity = DeviceIdentity.shared
    private let callKit = CallKitManager.shared
    private var signaling: SignalingClient?
    private var voipToken: String?

    private static let registrationKey = "registration"

    init() {
        registration = Keychain.readJSON(Self.registrationKey, as: Registration.self)
        callManager = CallManager(selfDeviceId: identity.deviceId)
        callManager.send = { [weak self] message in self?.signaling?.send(message) }
        callKit.onVoipToken = { [weak self] token in
            self?.voipToken = token
            self?.signaling?.send(.pushRegister(voipToken: token))
        }
        callKit.onIncomingPush = { [weak self] _, _ in self?.connectIfRegistered() }
        connectIfRegistered()
    }

    var selfDeviceId: String { identity.deviceId }
    var isOwner: Bool { registration?.selfMember.isOwner ?? false }
    var maxMembers: Int { 5 }

    // MARK: Registration

    func createGroup(serverURL: URL, setupToken: String, groupName: String, deviceName: String) async throws {
        let api = APIClient(baseURL: serverURL, identity: identity)
        let response = try await api.createGroup(setupToken: setupToken, groupName: groupName, deviceName: deviceName)
        completeRegistration(serverURL: serverURL, response: response)
    }

    func joinGroup(link: InviteLink, deviceName: String) async throws {
        let api = APIClient(baseURL: link.serverURL, identity: identity)
        let response = try await api.join(inviteToken: link.token, deviceName: deviceName)
        completeRegistration(serverURL: link.serverURL, response: response)
        pendingInviteLink = nil
    }

    private func completeRegistration(serverURL: URL, response: RegistrationResponse) {
        let reg = Registration(serverURL: serverURL, groupName: response.group.name, selfMember: response.selfMember)
        Keychain.writeJSON(Self.registrationKey, reg)
        registration = reg
        members = response.members
        connectIfRegistered()
    }

    private func clearRegistration(message: String?) {
        if callManager.isInCall { callManager.hangUp() }
        signaling?.delegate = nil
        signaling?.disconnect()
        signaling = nil
        Keychain.delete(Self.registrationKey)
        registration = nil
        members = []
        callState = .idle
        invite = nil
        connectionStatus = .disconnected
        if let message { alertMessage = message }
    }

    /// Non-owner: remove this device from the group. Owner: wipe local state only
    /// (the server keeps the group; reset it by deleting its data file).
    func leaveGroup() {
        if !isOwner { signaling?.send(.memberRemove(deviceId: selfDeviceId)) }
        clearRegistration(message: nil)
    }

    // MARK: Connection

    func connectIfRegistered() {
        guard let registration else { return }
        if signaling == nil {
            let client = SignalingClient(serverURL: registration.serverURL, identity: identity)
            client.delegate = self
            client.onStatusChange = { [weak self] status in self?.connectionStatus = status }
            signaling = client
        }
        signaling?.connect()
    }

    func disconnectIfIdle() {
        guard !callManager.isInCall, !callKit.isRinging else { return }
        signaling?.disconnect()
    }

    // MARK: Group management

    func createInvite() { signaling?.send(.inviteCreate) }

    func revokeInvite() {
        invite = nil
        signaling?.send(.inviteRevoke)
    }

    func removeMember(_ deviceId: String) { signaling?.send(.memberRemove(deviceId: deviceId)) }

    // MARK: Calls

    func startOrJoinCall() {
        guard let registration else { return }
        callManager.startCall(groupName: registration.groupName)
    }

    // MARK: URL handling

    func handleOpenURL(_ url: URL) {
        guard registration == nil else {
            alertMessage = "この端末はすでにグループに登録されています。"
            return
        }
        guard let link = InviteLink(url: url) else {
            alertMessage = "招待リンクが正しくありません。"
            return
        }
        pendingInviteLink = link
    }

    // MARK: SignalingClientDelegate

    func signaling(_ client: SignalingClient, didConnect welcome: Welcome) {
        members = welcome.members
        callState = welcome.call
        callManager.iceServers = welcome.iceServers
        if var reg = registration {
            reg.groupName = welcome.group.name
            reg.selfMember = welcome.selfMember
            if reg != registration {
                Keychain.writeJSON(Self.registrationKey, reg)
                registration = reg
            }
        }
        if let voipToken { client.send(.pushRegister(voipToken: voipToken)) }
        callManager.signalingReconnected()
        callManager.handle(callState: welcome.call)
    }

    func signaling(_ client: SignalingClient, didReceive message: ServerMessage) {
        switch message {
        case let .membersUpdated(list):
            members = list
            if members.count >= maxMembers { invite = nil }
        case let .callState(state):
            callState = state
            callManager.handle(callState: state)
        case let .signal(from, payload):
            callManager.handle(signal: from, payload: payload)
        case let .inviteCreated(inv):
            invite = inv
        case .inviteRevoked:
            invite = nil
        case let .error(code, _):
            alertMessage = ErrorText.forCode(code)
        case .welcome, .challenge, .pushRegistered, .pong, .unknown:
            break
        }
    }

    func signaling(_ client: SignalingClient, didDisconnect reason: SignalingClient.DisconnectReason) {
        switch reason {
        case .removed:
            clearRegistration(message: ErrorText.forCode("removed"))
        case .unauthorized:
            clearRegistration(message: "この端末の登録がサーバーに見つかりません。再度招待を受けてください。")
        case .replaced:
            alertMessage = "別の接続に置き換えられました。アプリを開き直してください。"
        case .closed, .network:
            break
        }
    }
}
