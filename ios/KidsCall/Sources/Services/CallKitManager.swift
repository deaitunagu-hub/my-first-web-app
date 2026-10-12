import AVFoundation
import CallKit
import Foundation
import PushKit

/// Bridges the system phone UI (CallKit) and VoIP pushes (PushKit) to the app.
/// All callbacks are delivered on the main thread.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?

    /// UUID of the call CallKit currently knows about (ringing, dialing or active).
    private(set) var activeCallUUID: UUID?
    /// True while an incoming call is ringing and not yet answered.
    private(set) var isRinging = false

    var onVoipToken: ((String) -> Void)? {
        didSet { if let t = lastVoipToken { onVoipToken?(t) } }
    }
    var onIncomingPush: ((_ callId: String?, _ callerName: String) -> Void)? {
        didSet {
            if let pending = pendingIncoming { pendingIncoming = nil; onIncomingPush?(pending.0, pending.1) }
        }
    }
    var onStartCall: (() -> Void)?
    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?
    var onMuteChanged: ((Bool) -> Void)?

    private var lastVoipToken: String?
    private var pendingIncoming: (String?, String)?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false   // nothing about the family lands in the Phone app history
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Call once at launch so VoIP pushes can wake the app.
    func start() {
        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }

    // MARK: Outgoing / answer / end

    func requestStartCall(groupName: String, fallback: @escaping () -> Void) {
        if isRinging { answerRingingCall(); return }
        guard activeCallUUID == nil else { return }
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: groupName))
        action.isVideo = true
        callController.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.activeCallUUID = nil
                    fallback()
                }
            }
        }
        activeCallUUID = uuid
    }

    func answerRingingCall() {
        guard let uuid = activeCallUUID, isRinging else { return }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { _ in }
    }

    /// Ends the CallKit call. `onEndCall` fires from the resulting action.
    func requestEndCall(fallback: @escaping () -> Void) {
        guard let uuid = activeCallUUID else { fallback(); return }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.activeCallUUID = nil
                    self?.isRinging = false
                    fallback()
                }
            }
        }
    }

    func reportConnected() {
        guard let uuid = activeCallUUID, !isRinging else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    /// The other side hung up (or the ringing call was cancelled).
    func reportRemoteEnded() {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        activeCallUUID = nil
        isRinging = false
    }

    // MARK: Incoming

    private func reportIncoming(callId: String?, callerName: String, completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        let uuid = UUID()

        if activeCallUUID != nil {
            // Already in (or ringing for) the family call: satisfy the PushKit
            // contract by reporting, then dismiss immediately.
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .answeredElsewhere)
                completion()
            }
            return
        }

        activeCallUUID = uuid
        isRinging = true
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                if error != nil {
                    self.activeCallUUID = nil
                    self.isRinging = false
                } else if let cb = self.onIncomingPush {
                    cb(callId, callerName)
                } else {
                    self.pendingIncoming = (callId, callerName)
                }
                completion()
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
        isRinging = false
        onEndCall?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        WebRTCClient.shared.configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        onStartCall?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        isRinging = false
        WebRTCClient.shared.configureAudioSession()
        onAnswerCall?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        activeCallUUID = nil
        isRinging = false
        onEndCall?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMuteChanged?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        WebRTCClient.shared.audioSessionDidActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        WebRTCClient.shared.audioSessionDidDeactivate(audioSession)
    }
}

// MARK: - PKPushRegistryDelegate

extension CallKitManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        lastVoipToken = token
        onVoipToken?(token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        lastVoipToken = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        let callerName = (dict["callerName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "家族"
        let callId = dict["callId"] as? String
        reportIncoming(callId: callId, callerName: callerName, completion: completion)
    }
}
