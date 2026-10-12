import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Shows the single live invite as a QR code. Owner only.
struct InviteView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let invite = appState.invite {
                    if invite.expiresAt > now {
                        if let image = qrImage(for: invite.url) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 280)
                                .padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text(invite.displayToken)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                        Text("相手の端末で KidsCall を開き、「招待QRコードを読み取る」でこの画面を読み取ってください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("残り \(remaining(invite.expiresAt))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ShareLink(item: invite.url) {
                            Label("リンクを送る", systemImage: "square.and.arrow.up")
                        }
                        .font(.footnote)
                        Button("この招待を取り消す", role: .destructive) {
                            appState.revokeInvite()
                            dismiss()
                        }
                    } else {
                        Text("招待の期限が切れました。")
                        Button("新しい招待を作る") { appState.createInvite() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("招待を作成中…")
                }
            }
            .padding(24)
            .navigationTitle("端末を招待")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onReceive(timer) { now = $0 }
            .onDisappear { appState.invite = nil }
        }
    }

    private func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
