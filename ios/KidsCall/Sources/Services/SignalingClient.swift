import Foundation

@MainActor
protocol SignalingClientDelegate: AnyObject {
    func signaling(_ client: SignalingClient, didConnect welcome: Welcome)
    func signaling(_ client: SignalingClient, didReceive message: ServerMessage)
    func signaling(_ client: SignalingClient, didDisconnect reason: SignalingClient.DisconnectReason)
}

/// Authenticated WebSocket to the group server. Handles the challenge/response
/// handshake, keep-alives and automatic reconnection with backoff.
@MainActor
final class SignalingClient {
    enum DisconnectReason: Equatable {
        case closed            // we closed it
        case network           // transient; will retry
        case replaced          // another connection from this device took over
        case removed           // this device was removed from the group
        case unauthorized      // server does not know this device
    }

    enum Status: Equatable { case disconnected, connecting, connected }

    private(set) var status: Status = .disconnected { didSet { onStatusChange?(status) } }
    var onStatusChange: ((Status) -> Void)?
    weak var delegate: SignalingClientDelegate?

    private let serverURL: URL
    private let identity: DeviceIdentity
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var outbox: [Data] = []
    private var draining = false
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var generation = 0

    init(serverURL: URL, identity: DeviceIdentity = .shared) {
        self.serverURL = serverURL
        self.identity = identity
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private var webSocketURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + "/v1/ws"
        components.query = nil
        return components.url!
    }

    // MARK: - Lifecycle

    func connect() {
        wantsConnection = true
        guard status == .disconnected else { return }
        open()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        status = .disconnected
        delegate?.signaling(self, didDisconnect: .closed)
    }

    private func open() {
        generation += 1
        let myGeneration = generation
        status = .connecting
        let task = session.webSocketTask(with: webSocketURL)
        self.task = task
        task.resume()
        Task { [weak self] in
            await self?.runHandshakeAndLoop(task: task, generation: myGeneration)
        }
    }

    private func teardown() {
        generation += 1
        outbox.removeAll()
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func runHandshakeAndLoop(task: URLSessionWebSocketTask, generation myGeneration: Int) async {
        do {
            guard case let .challenge(nonce) = try await receive(task) else {
                throw SignalingError.protocolError
            }
            try await send(.auth(publicKey: identity.publicKeyBase64, signature: identity.authSignature(nonce: nonce)), on: task)
            let first = try await receive(task)
            guard generation == myGeneration else { return }
            switch first {
            case let .welcome(welcome):
                reconnectAttempt = 0
                status = .connected
                startPings(task: task, generation: myGeneration)
                delegate?.signaling(self, didConnect: welcome)
                drainOutbox()
            case let .error(code, _):
                throw SignalingError.rejected(code)
            default:
                throw SignalingError.protocolError
            }
            while generation == myGeneration {
                let message = try await receive(task)
                guard generation == myGeneration else { return }
                if case .error(let code, _) = message, code == "removed" || code == "replaced" || code == "unauthorized" {
                    throw SignalingError.rejected(code)
                }
                delegate?.signaling(self, didReceive: message)
            }
        } catch {
            guard generation == myGeneration else { return }
            handleFailure(error, task: task)
        }
    }

    private func handleFailure(_ error: Error, task: URLSessionWebSocketTask) {
        teardown()
        status = .disconnected
        var reason: DisconnectReason = .network
        if case let SignalingError.rejected(code) = error {
            switch code {
            case "removed": reason = .removed
            case "replaced": reason = .replaced
            case "unauthorized": reason = .unauthorized
            default: break
            }
        }
        switch task.closeCode.rawValue {
        case 4000: reason = .replaced
        case 4001: reason = .removed
        case 4003: reason = .unauthorized
        default: break
        }
        if reason != .network { wantsConnection = false }
        delegate?.signaling(self, didDisconnect: reason)
        scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() {
        guard wantsConnection, status == .disconnected else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantsConnection, self.status == .disconnected else { return }
            self.open()
        }
    }

    private func startPings(task: URLSessionWebSocketTask, generation myGeneration: Int) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.generation == myGeneration, !Task.isCancelled else { return }
                task.sendPing { error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == myGeneration else { return }
                        self.handleFailure(error, task: task)
                    }
                }
            }
        }
    }

    // MARK: - I/O

    /// Queues a message. Messages are sent strictly in order; anything queued
    /// while (re)connecting is flushed once the socket is authenticated.
    func send(_ message: ClientMessage) {
        guard wantsConnection, let data = try? message.encode() else { return }
        outbox.append(data)
        drainOutbox()
    }

    private func drainOutbox() {
        guard !draining, status == .connected, let task else { return }
        draining = true
        let myGeneration = generation
        Task { [weak self] in
            defer { self?.draining = false }
            while true {
                guard let self, self.generation == myGeneration, !self.outbox.isEmpty else { return }
                let data = self.outbox.removeFirst()
                do {
                    try await task.send(.string(String(decoding: data, as: UTF8.self)))
                } catch {
                    guard self.generation == myGeneration else { return }
                    self.handleFailure(error, task: task)
                    return
                }
            }
        }
    }

    private func send(_ message: ClientMessage, on task: URLSessionWebSocketTask) async throws {
        let data = try message.encode()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> ServerMessage {
        let frame = try await task.receive()
        switch frame {
        case let .string(text):
            return try ServerMessage.decode(Data(text.utf8))
        case let .data(data):
            return try ServerMessage.decode(data)
        @unknown default:
            throw SignalingError.protocolError
        }
    }

    enum SignalingError: Error {
        case protocolError
        case rejected(String)
    }
}
