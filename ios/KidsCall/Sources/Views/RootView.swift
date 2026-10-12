import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var callManager: CallManager

    var body: some View {
        Group {
            if appState.registration == nil {
                OnboardingView()
            } else {
                HomeView()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { callManager.isInCall }, set: { _ in })) {
            CallView()
        }
        .alert("お知らせ", isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }
}
