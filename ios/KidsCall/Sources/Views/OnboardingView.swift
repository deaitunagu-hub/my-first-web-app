import SwiftUI

/// First screen on an unregistered device: join by invite, or (for the very
/// first phone only) create the family group.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showScanner = false
    @State private var showCreate = false
    @State private var pastedLink = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "video.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("KidsCall")
                    .font(.largeTitle.bold())
                Text("家族だけのビデオ通話。\n招待された端末だけが参加できます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    showScanner = true
                } label: {
                    Label("招待QRコードを読み取る", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(spacing: 8) {
                    TextField("または招待リンクを貼り付け", text: $pastedLink)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("リンクで参加") {
                        if let link = InviteLink(string: pastedLink) {
                            appState.pendingInviteLink = link
                        } else {
                            appState.alertMessage = "招待リンクが正しくありません。"
                        }
                    }
                    .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("最初の1台として設定する（管理者）") { showCreate = true }
                    .font(.footnote)
                    .padding(.top, 8)
            }
            .padding(24)
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    if let link = InviteLink(string: code) {
                        appState.pendingInviteLink = link
                    } else {
                        appState.alertMessage = "このQRコードはKidsCallの招待ではありません。"
                    }
                }
            }
            .sheet(isPresented: $showCreate) { CreateGroupView() }
            .sheet(item: Binding(get: { appState.pendingInviteLink }, set: { appState.pendingInviteLink = $0 })) { link in
                JoinGroupView(link: link)
            }
        }
    }
}

extension InviteLink: Identifiable {
    var id: String { serverURL.absoluteString + "|" + token }
}

struct JoinGroupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let link: InviteLink
    @State private var deviceName = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("参加先") {
                    LabeledContent("サーバー", value: link.serverURL.host ?? "")
                }
                Section("この端末の名前") {
                    TextField("例: ママ、たろう", text: $deviceName)
                }
                Section {
                    Button {
                        join()
                    } label: {
                        if busy { ProgressView() } else { Text("グループに参加する") }
                    }
                    .disabled(busy || deviceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("招待で参加")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
            .interactiveDismissDisabled(busy)
        }
    }

    private func join() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await appState.joinGroup(link: link, deviceName: deviceName.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                appState.alertMessage = error.localizedDescription
            }
        }
    }
}

struct CreateGroupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var serverURLText = "https://"
    @State private var setupToken = ""
    @State private var groupName = "家族"
    @State private var deviceName = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("自分で用意したサーバーに最初の1台を登録します。この端末が管理者になり、他の端末を招待できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("サーバー") {
                    TextField("https://call.example.com", text: $serverURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("セットアップ用の合言葉 (SETUP_TOKEN)", text: $setupToken)
                }
                Section("グループ") {
                    TextField("グループ名", text: $groupName)
                    TextField("この端末の名前", text: $deviceName)
                }
                Section {
                    Button {
                        create()
                    } label: {
                        if busy { ProgressView() } else { Text("グループを作成する") }
                    }
                    .disabled(busy || !canSubmit)
                }
            }
            .navigationTitle("最初の1台を設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
            .interactiveDismissDisabled(busy)
        }
    }

    private var serverURL: URL? {
        guard let url = URL(string: serverURLText.trimmingCharacters(in: .whitespaces)),
              InviteLink.isAcceptableServer(url) else { return nil }
        return url
    }

    private var canSubmit: Bool {
        serverURL != nil && !setupToken.isEmpty
            && !groupName.trimmingCharacters(in: .whitespaces).isEmpty
            && !deviceName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        guard let serverURL else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await appState.createGroup(
                    serverURL: serverURL,
                    setupToken: setupToken,
                    groupName: groupName.trimmingCharacters(in: .whitespaces),
                    deviceName: deviceName.trimmingCharacters(in: .whitespaces)
                )
                dismiss()
            } catch {
                appState.alertMessage = error.localizedDescription
            }
        }
    }
}
