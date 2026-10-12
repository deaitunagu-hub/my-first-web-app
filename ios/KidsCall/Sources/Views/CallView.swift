import SwiftUI
import WebRTC

/// The in-call screen: a grid of the other participants plus a small self view.
struct CallView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var callManager: CallManager

    private var columns: [GridItem] {
        let count = callManager.remotePeers.count
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count <= 1 ? 1 : 2)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if callManager.remotePeers.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("ほかの人が来るのを待っています…")
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let rows = max(1, Int(ceil(Double(callManager.remotePeers.count) / Double(columns.count))))
                    let tileHeight = max(120, (geo.size.height - 120) / CGFloat(rows))
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(callManager.remotePeers) { peer in
                                remoteTile(peer).frame(height: tileHeight)
                            }
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)
            }

            // Self preview
            VideoView(track: callManager.localVideoTrack, mirrored: true)
                .frame(width: 110, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6), lineWidth: 1))
                .padding(16)
                .opacity(callManager.isCameraOff ? 0.3 : 1)

            VStack {
                Spacer()
                controls
            }
        }
        .statusBarHidden(true)
    }

    private func remoteTile(_ peer: RemotePeer) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let track = peer.videoTrack {
                VideoView(track: track)
            } else {
                Color(white: 0.15)
                VStack {
                    Image(systemName: "person.fill").font(.largeTitle)
                    Text(statusText(peer.connectionState)).font(.caption)
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(peer.name)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusText(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new, .connecting: return "接続中…"
        case .connected: return "カメラがオフです"
        case .disconnected: return "再接続中…"
        case .failed: return "接続できません"
        case .closed: return "終了"
        @unknown default: return ""
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            controlButton(systemImage: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                          active: callManager.isMuted) { callManager.isMuted.toggle() }
            controlButton(systemImage: callManager.isCameraOff ? "video.slash.fill" : "video.fill",
                          active: callManager.isCameraOff) { callManager.isCameraOff.toggle() }
            controlButton(systemImage: "arrow.triangle.2.circlepath.camera.fill", active: false) { callManager.switchCamera() }
            Button {
                callManager.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.red, in: Circle())
            }
        }
        .padding(.bottom, 32)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private func controlButton(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(active ? .black : .white)
                .frame(width: 56, height: 56)
                .background(active ? Color.white : Color.white.opacity(0.25), in: Circle())
        }
    }
}
