import Foundation
import WebRTC

struct RemotePeer: Identifiable {
    let deviceId: String
    var name: String
    var videoTrack: RTCVideoTrack?
    var connectionState: RTCPeerConnectionState = .new
    var id: String { deviceId }
}

/// Runs the full-mesh call: one peer connection per other participant.
/// Who sends the offer is decided by the server-assigned join order
/// (`seq`): the later joiner offers to everyone already there.
@MainActor
final class CallManager: ObservableObject {
    @Published private(set) var isInCall = false
    @Published private(set) var remotePeers: [RemotePeer] = []
    @Published var isMuted = false { didSet { webrtc.setMuted(isMuted) } }
    @Published var isCameraOff = false { didSet { webrtc.setVideoEnabled(!isCameraOff) } }

    var localVideoTrack: RTCVideoTrack? { webrtc.localVideoTrack }
    var iceServers: [IceServerInfo] = []
    var send: ((ClientMessage) -> Void)?

    private let selfDeviceId: String
    private let webrtc = WebRTCClient.shared
    private let callKit = CallKitManager.shared
    private var peers: [String: PeerConnection] = [:]
    private var lastState: CallState = .idle

    init(selfDeviceId: String) {
        self.selfDeviceId = selfDeviceId
        callKit.onStartCall = { [weak self] in self?.joinCallNow() }
        callKit.onAnswerCall = { [weak self] in self?.joinCallNow() }
        callKit.onEndCall = { [weak self] in self?.leaveCallNow() }
        callKit.onMuteChanged = { [weak self] muted in self?.isMuted = muted }
    }

    // MARK: User intents

    func startCall(groupName: String) {
        guard !isInCall else { return }
        callKit.requestStartCall(groupName: groupName) { [weak self] in self?.joinCallNow() }
    }

    func hangUp() {
        callKit.requestEndCall { [weak self] in self?.leaveCallNow() }
    }

    func switchCamera() { webrtc.switchCamera() }

    // MARK: Internal transitions

    private func joinCallNow() {
        guard !isInCall else { return }
        webrtc.startLocalMedia()
        webrtc.setMuted(isMuted)
        webrtc.setVideoEnabled(!isCameraOff)
        isInCall = true
        send?(.callJoin)
    }

    private func leaveCallNow() {
        let wasInCall = isInCall
        isInCall = false
        for (_, peer) in peers { peer.close() }
        peers = [:]
        remotePeers = []
        webrtc.stopLocalMedia()
        if wasInCall { send?(.callLeave) }
    }

    // MARK: Signaling events

    func signalingReconnected() {
        guard isInCall else { return }
        // The server dropped us from the call when the socket died; start over.
        for (_, peer) in peers { peer.close() }
        peers = [:]
        remotePeers = []
        send?(.callJoin)
    }

    func handle(callState state: CallState) {
        lastState = state
        if !isInCall {
            // Caller hung up before we answered.
            if state.participants.isEmpty, callKit.isRinging { callKit.reportRemoteEnded() }
            return
        }
        guard let me = state.participants.first(where: { $0.deviceId == selfDeviceId }) else { return }
        let others = state.participants.filter { $0.deviceId != selfDeviceId }

        for id in Array(peers.keys) where !others.contains(where: { $0.deviceId == id }) {
            removePeer(id)
        }
        for p in others where peers[p.deviceId] == nil {
            guard let peer = createPeer(deviceId: p.deviceId, name: p.name) else { continue }
            if p.seq < me.seq {
                Task { await sendOffer(peer) }
            }
        }
        for p in others {
            if let i = remotePeers.firstIndex(where: { $0.deviceId == p.deviceId }) { remotePeers[i].name = p.name }
        }
        if !others.isEmpty { callKit.reportConnected() }
    }

    func handle(signal from: String, payload: SignalPayload) {
        guard isInCall else { return }
        let name = lastState.participants.first(where: { $0.deviceId == from })?.name ?? ""
        guard let peer = peers[from] ?? createPeer(deviceId: from, name: name) else { return }
        Task {
            do {
                switch payload.type {
                case "offer":
                    guard let sdp = payload.sdp else { return }
                    try await peer.applyRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
                    let answer = try await peer.makeAnswer()
                    try await peer.applyLocalDescription(answer)
                    send?(.signal(to: from, payload: SignalPayload(type: "answer", sdp: answer.sdp)))
                case "answer":
                    guard let sdp = payload.sdp else { return }
                    try await peer.applyRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                case "candidate":
                    guard let candidate = payload.candidate else { return }
                    try await peer.addRemoteCandidate(RTCIceCandidate(sdp: candidate, sdpMLineIndex: payload.sdpMLineIndex ?? 0, sdpMid: payload.sdpMid))
                default:
                    break
                }
            } catch {
                NSLog("[call] signal \(payload.type) from \(from) failed: \(error)")
            }
        }
    }

    // MARK: Peers

    private func createPeer(deviceId: String, name: String) -> PeerConnection? {
        guard let peer = try? webrtc.makePeer(remoteDeviceId: deviceId, iceServers: iceServers) else { return nil }
        peer.onLocalIceCandidate = { [weak self] c in
            Task { @MainActor in
                self?.send?(.signal(to: deviceId, payload: SignalPayload(
                    type: "candidate", candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)))
            }
        }
        peer.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in self?.update(deviceId) { $0.videoTrack = track } }
        }
        peer.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in self?.update(deviceId) { $0.connectionState = state } }
        }
        peers[deviceId] = peer
        remotePeers.append(RemotePeer(deviceId: deviceId, name: name))
        return peer
    }

    private func removePeer(_ deviceId: String) {
        peers[deviceId]?.close()
        peers[deviceId] = nil
        remotePeers.removeAll { $0.deviceId == deviceId }
    }

    private func update(_ deviceId: String, _ change: (inout RemotePeer) -> Void) {
        guard let i = remotePeers.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        change(&remotePeers[i])
    }

    private func sendOffer(_ peer: PeerConnection) async {
        do {
            let offer = try await peer.makeOffer()
            try await peer.applyLocalDescription(offer)
            send?(.signal(to: peer.remoteDeviceId, payload: SignalPayload(type: "offer", sdp: offer.sdp)))
        } catch {
            NSLog("[call] offer to \(peer.remoteDeviceId) failed: \(error)")
        }
    }
}
