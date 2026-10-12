import AVFoundation
import Foundation
import WebRTC

/// One RTCPeerConnection towards one other family member.
final class PeerConnection: NSObject, RTCPeerConnectionDelegate {
    let remoteDeviceId: String
    let pc: RTCPeerConnection
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    var onRemoteVideoTrack: (@Sendable (RTCVideoTrack?) -> Void)?
    var onLocalIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    var onConnectionStateChange: (@Sendable (RTCPeerConnectionState) -> Void)?

    init(remoteDeviceId: String, pc: RTCPeerConnection) {
        self.remoteDeviceId = remoteDeviceId
        self.pc = pc
        super.init()
        pc.delegate = self
    }

    func close() {
        pc.delegate = nil
        pc.close()
        remoteVideoTrack = nil
    }

    // MARK: Async wrappers (names chosen not to clash with the SDK's own async overloads)

    func makeOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.offer(for: Self.constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: error ?? WebRTCError.noDescription) }
            }
        }
    }

    func makeAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.answer(for: Self.constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: error ?? WebRTCError.noDescription) }
            }
        }
    }

    func applyLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func applyRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        hasRemoteDescription = true
        let queued = pendingCandidates
        pendingCandidates = []
        for c in queued { try? await addRemoteCandidate(c) }
    }

    func addRemoteCandidate(_ candidate: RTCIceCandidate) async throws {
        guard hasRemoteDescription else {
            pendingCandidates.append(candidate)
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private static let constraints = RTCMediaConstraints(
        mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
        optionalConstraints: nil
    )

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // The app has no data channel feature; close anything a peer tries to open.
        dataChannel.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalIceCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onConnectionStateChange?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            remoteVideoTrack = track
            onRemoteVideoTrack?(track)
        }
    }
}

enum WebRTCError: Error {
    case noDescription
    case factoryFailure
}

/// Owns the peer connection factory and the local camera/microphone.
final class WebRTCClient {
    static let shared = WebRTCClient()

    private let factory: RTCPeerConnectionFactory
    private var audioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var usingFrontCamera = true

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.useManualAudio = true   // CallKit drives activation
        audioSession.isAudioEnabled = false
    }

    // MARK: Local media

    func startLocalMedia() {
        if audioTrack == nil {
            let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            audioTrack = factory.audioTrack(with: source, trackId: "audio0")
        }
        if localVideoTrack == nil {
            let source = factory.videoSource()
            videoSource = source
            localVideoTrack = factory.videoTrack(with: source, trackId: "video0")
            capturer = RTCCameraVideoCapturer(delegate: source)
        }
        startCapture()
    }

    func stopLocalMedia() {
        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        localVideoTrack = nil
        audioTrack = nil
    }

    func setMuted(_ muted: Bool) { audioTrack?.isEnabled = !muted }
    func setVideoEnabled(_ enabled: Bool) { localVideoTrack?.isEnabled = enabled }

    func switchCamera() {
        usingFrontCamera.toggle()
        startCapture()
    }

    private func startCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Prefer a modest resolution: five phones in a mesh share one uplink.
        let targetWidth: Int32 = 640
        let format = formats.min { a, b in
            let wa = CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
            let wb = CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
            return abs(wa - targetWidth) < abs(wb - targetWidth)
        } ?? formats.last
        guard let format else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(maxFps, 24)))
    }

    // MARK: Peer connections

    func makePeer(remoteDeviceId: String, iceServers: [IceServerInfo]) throws -> PeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw WebRTCError.factoryFailure
        }
        if let audioTrack { pc.add(audioTrack, streamIds: ["kidscall"]) }
        if let localVideoTrack { pc.add(localVideoTrack, streamIds: ["kidscall"]) }
        return PeerConnection(remoteDeviceId: remoteDeviceId, pc: pc)
    }

    // MARK: Audio session (driven by CallKit callbacks)

    func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        try? session.setConfiguration(config)
    }

    func audioSessionDidActivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
    }

    func audioSessionDidDeactivate(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
    }
}
