import SwiftUI

struct VariedTabbarView: View {
    @StateObject private var installer = UUInstallCoordinator.shared
    var body: some View {
        VStack(spacing: 0) {
            if installer.busy {
                HStack { ProgressView(); Text(installer.status).font(.footnote) }.padding(10)
            }
            TabbarView().tint(Color(red: 0.66, green: 0.33, blue: 0.97))
        }
        .task { await installer.prepare() }
        .sheet(item: $installer.installApp) { app in
            InstallPreviewView(app: app.base)
        }
        .alert("UU 安裝", isPresented: Binding(get: { installer.error != nil }, set: { if !$0 { installer.error = nil } })) {
            Button("知道了") { installer.error = nil }
        } message: { Text(installer.error ?? "") }
    }
}

