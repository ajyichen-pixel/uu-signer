// UU Store customization, 2026-11-12. Based on Feather, GPL-3.0.
import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews

struct SourcesView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @ObservedObject private var installer = UUInstallCoordinator.shared
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
                    Text("選擇遊戲，按安裝即可自動下載與簽署。")
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
                Section("我的裝置") {
                    Label(installer.status, systemImage: installer.ready ? "checkmark.seal.fill" : "clock")
                    if !installer.ready {
                        Text("購買完成並取得專屬安裝包後，憑證會自動設定，不需選檔或輸入憑證密碼。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新檢查") { Task { await installer.prepare() } }
                            .disabled(installer.busy)
                    }
                    Link("我的訂單", destination: URL(string: "https://uuxp.click/#orders")!)
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

