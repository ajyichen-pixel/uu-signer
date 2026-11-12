// UU Store customization, 2026-11-12. Based on Feather, GPL-3.0.
import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

struct SourcesView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @State private var sourceError: String?
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>
    private var uuSources: [AltSource] {
        sources.filter { $0.sourceURL?.absoluteString == "https://uuxp.click/source.json" }
    }
    var body: some View {
        NBNavigationView("UU 商店") {
            List {
                Section {
                    Text("UU 遊戲").font(.largeTitle.bold())
                    Text("選擇遊戲，下載後使用自己的憑證簽署安裝。")
                        .foregroundStyle(.secondary)
                    if let sourceError {
                        Text(sourceError).foregroundStyle(.red)
                        Button("重新載入") { installBuiltInSource() }
                    }
                    if !uuSources.isEmpty {
                        NavigationLink {
                            SourceAppsView(object: uuSources, viewModel: viewModel)
                        } label: {
                            Label("選擇遊戲", systemImage: "gamecontroller.fill")
                                .font(.title3.bold())
                        }
                    } else {
                        ProgressView("準備 UU 商店…")
                    }
                }
                Section("首次使用") {
                    NavigationLink {
                        CertificatesView()
                    } label: {
                        Label("匯入／管理簽署憑證", systemImage: "checkmark.seal")
                    }
                    Link("購買憑證（外部服務）", destination: URL(string: "https://www.udidregistrations.com/buy")!)
                    Text("購買後匯入 P12、描述檔與憑證密碼。憑證依裝置計費，與 UU 遊戲時間分開；目前尚未完成本版本實機驗證。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("下載之後") {
                    NavigationLink { LibraryView() } label: {
                        Label("簽署與安裝", systemImage: "signature")
                    }
                    Text("在遊戲庫選擇下載的遊戲，簽署完成後按安裝。iOS 仍會要求系統確認。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("UU 授權商店", destination: URL(string: "https://uuxp.click/")!)
                }
                Section("開源授權") {
                    Text("UU 簽署是 Feather 的客製版本，使用 Zsign 簽署引擎。保留原作者版權，以 GPL-3.0 提供修改後原始碼。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Feather 原始專案", destination: URL(string: "https://github.com/claration/Feather")!)
                }
            }
            .refreshable { await viewModel.fetchSources(sources, refresh: true) }
        }
        .task { installBuiltInSource() }
        .task(id: Array(sources)) { await viewModel.fetchSources(sources) }
    }
    @MainActor private func installBuiltInSource() {
        guard uuSources.isEmpty else { return }
        Storage.shared.addSource(
            URL(string: "https://uuxp.click/source.json")!,
            name: "UU 遊戲", identifier: "click.uuxp.source",
            iconURL: URL(string: "https://uuxp.click/uu.png")
        ) { error in
            sourceError = error == nil ? nil : "無法儲存 UU 來源，請重試。"
        }
    }
}
