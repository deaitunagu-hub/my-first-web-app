import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showInvite = false
    @State private var memberToRemove: Member?
    @State private var confirmLeave = false

    private var othersInCall: [Participant] {
        appState.callState.participants.filter { $0.deviceId != appState.selfDeviceId }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    callCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(appState.members) { member in
                        HStack {
                            Image(systemName: member.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                .foregroundStyle(member.deviceId == appState.selfDeviceId ? Color.accentColor : .secondary)
                            Text(member.name)
                            if member.deviceId == appState.selfDeviceId {
                                Text("（この端末）").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if appState.callState.participants.contains(where: { $0.deviceId == member.deviceId }) {
                                Label("通話中", systemImage: "video.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                            }
                        }
                        .swipeActions {
                            if appState.isOwner && !member.isOwner {
                                Button(role: .destructive) { memberToRemove = member } label: {
                                    Label("外す", systemImage: "person.badge.minus")
                                }
                            }
                        }
                    }
                } header: {
                    Text("メンバー \(appState.members.count) / \(appState.maxMembers) 台")
                } footer: {
                    if appState.isOwner {
                        Text("メンバーの追加・削除はこの端末（管理者）だけができます。")
                    }
                }

                if appState.isOwner {
                    Section {
                        Button {
                            appState.createInvite()
                            showInvite = true
                        } label: {
                            Label("新しい端末を招待する", systemImage: "qrcode")
                        }
                        .disabled(appState.members.count >= appState.maxMembers || appState.connectionStatus != .connected)
                    } footer: {
                        if appState.members.count >= appState.maxMembers {
                            Text("5台に達しています。招待するには先に端末を外してください。")
                        } else {
                            Text("招待は10分間・1回だけ使えるQRコードです。相手に直接見せてください。")
                        }
                    }
                }
            }
            .navigationTitle(appState.registration?.groupName ?? "KidsCall")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { connectionBadge }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmLeave = true } label: {
                            Label(appState.isOwner ? "この端末の設定を消去" : "グループから抜ける", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showInvite) { InviteView() }
            .task { await Permissions.requestCameraAndMicrophone() }
            .confirmationDialog("「\(memberToRemove?.name ?? "")」をグループから外しますか？", isPresented: Binding(
                get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }
            ), titleVisibility: .visible) {
                Button("外す", role: .destructive) {
                    if let m = memberToRemove { appState.removeMember(m.deviceId) }
                    memberToRemove = nil
                }
                Button("キャンセル", role: .cancel) { memberToRemove = nil }
            } message: {
                Text("外した端末は再度招待しない限り二度と参加できません。")
            }
            .confirmationDialog(appState.isOwner ? "この端末の設定を消去しますか？" : "グループから抜けますか？", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button(appState.isOwner ? "消去する" : "抜ける", role: .destructive) { appState.leaveGroup() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(appState.isOwner
                     ? "サーバー上のグループは残ります。戻るにはサーバーのデータを初期化する必要があります。"
                     : "戻るには管理者から新しい招待をもらう必要があります。")
            }
        }
    }

    private var callCard: some View {
        VStack(spacing: 16) {
            if othersInCall.isEmpty {
                Image(systemName: "video")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("いま通話中の人はいません")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("通話中: " + othersInCall.map(\.name).joined(separator: "、"))
                    .multilineTextAlignment(.center)
            }
            Button {
                appState.startOrJoinCall()
            } label: {
                Label(othersInCall.isEmpty ? "みんなに電話する" : "通話に参加する", systemImage: "phone.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(appState.connectionStatus != .connected)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.vertical, 8)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appState.connectionStatus == .connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(appState.connectionStatus == .connected ? "接続中" : "接続待ち")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
