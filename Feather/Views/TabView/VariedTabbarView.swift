import SwiftUI
import Security

// Native UI. Signing keys remain on the private signing host.
struct VariedTabbarView: View {
    @StateObject private var store = UUNativeStoreModel()
    var body: some View {
        UUNativeStoreView(store: store)
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.78, green: 0.52, blue: 1))
    }
}

private struct UUAccount: Decodable { let id: String; let email: String }
private struct UUAccountReply: Decodable { let user: UUAccount? }
private struct UUPackage: Decodable, Identifiable {
    let id: String; let bundleId: String; let title: String; let version: String
    let deviceLabel: String; let status: String; let expires: Double
}
private struct UUPackages: Decodable { let installations: [UUPackage] }
private struct UUJob: Decodable, Identifiable { let id: String; let status: String; let deviceLabel: String }
private struct UUJobs: Decodable { let jobs: [UUJob] }
private struct UULink: Decodable { let installURL: String }
private struct UUFailure: Decodable { let error: String }
private struct UUSavedLogin: Codable { let token: String; let expires: Date }
private struct UUDownloadRecord: Codable, Identifiable {
    let id: String; let title: String; let version: String; let file: String
}
private enum UUStoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
private enum UULoginVault {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "click.uuxp.signer.native", kSecAttrAccount as String: "session"]
    static func read() -> UUSavedLogin? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let item = try? JSONDecoder().decode(UUSavedLogin.self, from: data), item.expires > Date() else { return nil }
        return item
    }
    static func save(_ value: UUSavedLogin) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UUStoreError.message("無法保存登入，請解鎖裝置後重試。") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
private final class UUNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor private final class UUNativeStoreModel: ObservableObject {
    @Published var account: UUAccount?
    @Published var packages: [UUPackage] = []
    @Published var jobs: [UUJob] = []
    @Published var email = ""
    @Published var password = ""
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var notice: String?
    @Published var downloadID: String?
    @Published var progress = 0.0
    @Published var records: [UUDownloadRecord] = []
    private var login = UULoginVault.read()
    private let redirectGuard = UUNoRedirect()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: redirectGuard, delegateQueue: nil)
    }()
    private var transfer: UUFileTransfer?
    private var refreshBusy = false
    private var generation = 0
    private var recordKey: String { "UU.native.downloads." + (account?.id ?? "none") }
    static let origin = "https://uuxp.click"
    private func request(_ path: String, body: [String: String]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: Self.origin + path)!)
        r.setValue(Self.origin, forHTTPHeaderField: "Origin")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("UUSignerNative/3.0", forHTTPHeaderField: "User-Agent")
        if let login, login.expires > Date() { r.setValue("__Host-uu_session=" + login.token, forHTTPHeaderField: "Cookie") }
        if let body { r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    private func call<T: Decodable>(_ path: String, body: [String: String]? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(path, body: body))
        guard let http = response as? HTTPURLResponse else { throw UUStoreError.message("伺服器沒有回應。") }
        if http.statusCode == 401 { clearSession() }
        guard (200..<300).contains(http.statusCode) else {
            throw UUStoreError.message((try? JSONDecoder().decode(UUFailure.self, from: data).error) ?? "服務暫時忙碌，請稍後重試。")
        }
        if path == "/api/login", let fields = http.allHeaderFields as? [String: String], let url = http.url,
           let c = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first(where: { $0.name == "__Host-uu_session" }),
           c.value.count == 64, c.value.allSatisfy({ $0.isHexDigit }) {
            let value = UUSavedLogin(token: c.value, expires: c.expiresDate ?? Date().addingTimeInterval(7 * 86400))
            try UULoginVault.save(value); login = value
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func start() async {
        loading = true; defer { loading = false }
        guard login != nil else { return }
        do {
            let reply: UUAccountReply = try await call("/api/me")
            account = reply.user
            if account == nil { clearSession(); return }
            loadRecords(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func signIn() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let reply: UUAccountReply = try await call("/api/login", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
            guard login != nil, reply.user != nil else { throw UUStoreError.message("無法保存登入，請再試一次。") }
            account = reply.user; password = ""; loadRecords(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func clearSession() {
        generation += 1; transfer?.cancel(); transfer = nil; downloadID = nil
        UULoginVault.clear(); login = nil; account = nil; packages = []; jobs = []; records = []
    }
    func signOut() async {
        struct Reply: Decodable { let ok: Bool }
        let _: Reply? = try? await call("/api/logout", body: [:])
        clearSession()
    }
    func refresh() async {
        guard account != nil, !refreshBusy else { return }
        refreshBusy = true; let current = generation
        defer { refreshBusy = false }
        do {
            let apps: UUPackages = try await call("/api/installations")
            let work: UUJobs = try await call("/api/installations/jobs")
            guard current == generation, account != nil else { return }
            var seen = Set<String>()
            packages = apps.installations.sorted {
                if ($0.status == "ready") != ($1.status == "ready") { return $0.status == "ready" }
                return $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }.filter { seen.insert($0.bundleId + ":" + $0.deviceLabel).inserted }
            jobs = work.jobs.filter { !["ready", "paused"].contains($0.status) }
        } catch { self.error = error.localizedDescription }
    }
    private func loadRecords() {
        records = (UserDefaults.standard.data(forKey: recordKey).flatMap { try? JSONDecoder().decode([UUDownloadRecord].self, from: $0) } ?? []).filter { FileManager.default.fileExists(atPath: $0.file) }
    }
    private func link(_ app: UUPackage) async throws -> URL {
        guard app.status == "ready", app.expires > Date().timeIntervalSince1970 else { throw UUStoreError.message("簽章期限已到，請先續期。") }
        let result: UULink = try await call("/api/installations/" + app.id + "/link", body: [:])
        guard let url = URL(string: result.installURL), url.scheme == "itms-services",
              let manifest = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: manifest), target.scheme == "https", target.host == "uuxp.click", target.path == "/install/" + app.id + "/manifest.plist" else { throw UUStoreError.message("安裝連結不正確，請重新整理。") }
        return url
    }
    func install(_ app: UUPackage) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let url = try await link(app)
            let opened = await UIApplication.shared.open(url)
            guard opened else { throw UUStoreError.message("iOS 無法開啟安裝，請稍後重試。") }
            notice = "請在 iOS 提示按「安裝」，回主畫面等待圖示完成。這裡尚不能確認安裝成功。"
        } catch { self.error = error.localizedDescription }
    }
    func download(_ app: UUPackage) async {
        guard downloadID == nil else { return }
        downloadID = app.id; progress = 0; let current = generation
        defer { downloadID = nil; transfer = nil }
        do {
            let ota = try await link(app)
            let manifest = URLComponents(url: ota, resolvingAgainstBaseURL: false)!.queryItems!.first(where: { $0.name == "url" })!.value!
            var components = URLComponents(string: manifest)!
            components.path = "/install/" + app.id + "/package.ipa"
            let task = UUFileTransfer()
            transfer = task
            let file = try await task.download(components.url!) { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            guard current == generation, account != nil else { try? FileManager.default.removeItem(at: file); return }
            records.removeAll { $0.id == app.id }
            records.append(UUDownloadRecord(id: app.id, title: app.title, version: app.version, file: file.path))
            UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: recordKey)
            notice = "IPA 已下載。按「安裝」後由 iOS 完成安裝。"
        } catch { if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription } }
    }
    func cancelDownload() { transfer?.cancel() }
    func remove(_ record: UUDownloadRecord) {
        try? FileManager.default.removeItem(atPath: record.file)
        records.removeAll { $0.id == record.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recordKey)
    }
}

// URLSession writes directly to disk; no 250 MB in-memory buffer or fake progress.
private final class UUFileTransfer: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: ((Double) -> Void)?
    func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        self.progress = progress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: url); self.task = task; task.resume()
        }
    }
    func cancel() { task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw UUStoreError.message("下載連結已到期，請重新下載。") }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 1024, response.expectedContentLength < 0 || Int64(size) == response.expectedContentLength else { throw UUStoreError.message("檔案未下載完整，請重試。") }
            let handle = try FileHandle(forReadingFrom: location); defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw UUStoreError.message("下載的檔案不是 IPA，請重試。") }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("UUPackages", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString + ".ipa")
            try FileManager.default.moveItem(at: location, to: file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            continuation?.resume(returning: file); continuation = nil
        } catch { continuation?.resume(throwing: error); continuation = nil }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
    }
}

private struct UUNativeStoreView: View {
    @ObservedObject var store: UUNativeStoreModel
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    private let purple = Color(red: 0.76, green: 0.45, blue: 1)
    var body: some View {
        Group {
            if store.loading { ProgressView("正在開啟 UU…") }
            else if store.account == nil { login }
            else {
                TabView(selection: $tab) {
                    NavigationStack { shop }.tabItem { Label("商店", systemImage: "bolt.fill") }.tag(0)
                    NavigationStack { downloads }.tabItem { Label("下載", systemImage: "arrow.down.circle.fill") }.tag(1)
                    NavigationStack { account }.tabItem { Label("帳號", systemImage: "person.crop.circle") }.tag(2)
                }
            }
        }
        .task { await store.start() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                await store.refresh()
            }
        }
        .alert("請稍候", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("UU 簽署", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("好") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
    private var login: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.16, green: 0.06, blue: 0.25)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 64)).foregroundStyle(purple)
                    Text("UU 簽署").font(.largeTitle.bold())
                    Text("登入，選遊戲，安裝。").foregroundStyle(.secondary)
                    TextField("Email", text: $store.email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密碼", text: $store.password).textContentType(.password).onSubmit { Task { await store.signIn() } }
                    Button { Task { await store.signIn() } } label: {
                        HStack { if store.busy { ProgressView() }; Text("登入").frame(maxWidth: .infinity) }
                    }.buttonStyle(.borderedProminent).disabled(store.busy || store.email.isEmpty || store.password.isEmpty)
                    Link("註冊／購買", destination: URL(string: "https://uuxp.click/#account")!)
                }.textFieldStyle(.roundedBorder).padding(28).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
    private var shop: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("你的遊戲，一鍵開始").font(.title2.bold())
                if store.packages.isEmpty { Text("購買後登記裝置，遊戲會顯示在這裡。").foregroundStyle(.secondary); Link("前往 UU 官網", destination: URL(string: "https://uuxp.click/#install")!) }
                ForEach(store.jobs) { job in
                    HStack {
                        Image(systemName: job.status == "awaiting_device" ? "iphone" : "signature")
                        Text(job.status == "awaiting_device" ? "請先登記裝置" : job.status == "failed" ? "簽署待處理" : "後台正在準備簽署…")
                    }.font(.subheadline).padding().background(purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                }
                ForEach(store.packages) { app in card(app) }
            }.padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .navigationTitle("UU 商店")
        .refreshable { await store.refresh() }
        .toolbar { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("檢查更新") }
    }
    private func card(_ app: UUPackage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: app.bundleId == "click.uuxp.signer" ? "bolt.shield.fill" : "gamecontroller.fill")
                    .font(.system(size: 36)).foregroundStyle(purple).frame(width: 64, height: 64)
                    .background(purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) { Text(app.title).font(.title3.bold()); Text("版本 " + app.version).font(.caption).foregroundStyle(.secondary) }
            }
            if app.status == "ready" {
                Label("已完成裝置簽署", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                HStack {
                    Button { Task { await store.install(app) } } label: { Label("安裝／更新", systemImage: "arrow.down.app.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(store.busy)
                    Button("下載 IPA") { Task { await store.download(app) } }.buttonStyle(.bordered).disabled(store.downloadID != nil)
                }
                if store.downloadID == app.id {
                    ProgressView(value: store.progress)
                    HStack { Text("下載中 " + String(Int(store.progress * 100)) + "%"); Spacer(); Button("取消") { store.cancelDownload() } }.font(.caption)
                }
            } else { Text(app.status == "expired" ? "簽章到期，請先續期。" : "安裝包準備中，完成後會自動顯示。").foregroundStyle(.secondary) }
            DisclosureGroup("裝置與期限") {
                Text("裝置尾碼 " + app.deviceLabel).frame(maxWidth: .infinity, alignment: .leading)
                Text("簽章至 " + Date(timeIntervalSince1970: app.expires).formatted(date: .numeric, time: .omitted)).frame(maxWidth: .infinity, alignment: .leading)
                Text("簽署由 UU 後台執行。遊戲時間依你的授權方案。").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(LinearGradient(colors: [purple.opacity(0.18), .black], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(purple.opacity(0.3)))
    }
    private var downloads: some View {
        List {
            if let _ = store.downloadID { Section("正在下載") { ProgressView(value: store.progress); Button("取消下載") { store.cancelDownload() } } }
            if store.records.isEmpty { Text("尚未下載 IPA。").foregroundStyle(.secondary) }
            ForEach(store.records) { record in
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.title).font(.headline); Text(record.version).font(.caption)
                    if let app = store.packages.first(where: { $0.id == record.id }) { Button("安裝") { Task { await store.install(app) } }.disabled(store.busy) }
                    Text("下載完成不代表已安裝。iOS 安裝時會重新取得已簽署的安裝包。").font(.caption).foregroundStyle(.secondary)
                    Button("移除下載", role: .destructive) { store.remove(record) }
                }.padding(.vertical, 6)
            }
        }.navigationTitle("下載")
    }
    private var account: some View {
        List {
            Section("UU 會員") { Text(store.account?.email ?? ""); Link("授權碼／訂單", destination: URL(string: "https://uuxp.click/#orders")!) }
            Section("使用方式") { Label("選擇遊戲，按安裝／更新", systemImage: "1.circle"); Label("在 iOS 提示按安裝", systemImage: "2.circle"); Label("回主畫面開啟遊戲", systemImage: "3.circle") }
            Section { Text("UU 原生介面 3.0 · SwiftUI").font(.caption); Link("開放原始碼與授權", destination: URL(string: "https://github.com/ajyichen-pixel/uu-signer")!); Button("登出", role: .destructive) { Task { await store.signOut() } } }
        }.navigationTitle("帳號")
    }
}
