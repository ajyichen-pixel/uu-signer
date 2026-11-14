import SwiftUI
import CoreData
import CryptoKit

/// Customer flow. Only device-personalized packages can install store games.
@MainActor final class UUInstallCoordinator: ObservableObject {
    static let shared = UUInstallCoordinator()
    @Published var busy = false
    @Published var status = "正在檢查裝置授權…"
    @Published var error: String?
    @Published var ready = false
    @Published var installApp: AnyApp?
    @Published private(set) var installedVersions = UserDefaults.standard.dictionary(forKey: "UU.installedVersions") as? [String: String] ?? [:]
    private var certificate: CertificatePair?

    func actionTitle(identifier: String?, remoteVersion: String?) -> String {
        guard let identifier, let local = installedVersions[identifier] else { return "安裝" }
        guard let remoteVersion, remoteVersion != local else { return "重新安裝" }
        return remoteVersion.compare(local, options: .numeric) == .orderedDescending ? "更新" : "重新安裝"
    }

    // Called only after the installer reports completion, not after signing or download.
    func recordInstallation(_ app: AppInfoPresentable) {
        guard app.uuid == installApp?.base.uuid,
              let identifier = app.identifier, let version = app.version else { return }
        installedVersions[identifier] = version
        UserDefaults.standard.set(installedVersions, forKey: "UU.installedVersions")
        status = "安裝完成，之後可從 UU 商店更新遊戲"
    }

    struct DeviceAssets: Decodable {
        let profileUUID: String
        let deviceUDID: String
        let password: String
        let p12SHA256: String
        let profileSHA256: String
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "UUInstall", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepare() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("UUDevice"),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("device.json").path) else {
                throw failure("這份安裝包尚未綁定裝置憑證，請從訂單下載專屬安裝包。")
            }
            let assets = try JSONDecoder().decode(DeviceAssets.self, from: Data(contentsOf: root.appendingPathComponent("device.json")))
            let key = root.appendingPathComponent("cert.p12")
            let profile = root.appendingPathComponent("cert.mobileprovision")
            guard hash(try Data(contentsOf: key)) == assets.p12SHA256,
                  hash(try Data(contentsOf: profile)) == assets.profileSHA256,
                  let decoded = CertificateReader(profile).decoded,
                  decoded.UUID == assets.profileUUID,
                  decoded.ProvisionedDevices == [assets.deviceUDID],
                  decoded.ExpirationDate > Date() else {
                throw failure("裝置憑證無效或已到期，請從訂單更新安裝包。")
            }
            let nickname = "UU-" + assets.profileUUID
            if let saved = Storage.shared.getAllCertificates().first(where: { $0.nickname == nickname }) {
                certificate = saved
            } else {
                guard FR.checkPasswordForCertificate(for: key, with: assets.password, using: profile) else {
                    throw failure("裝置憑證驗證失敗，請聯絡客服重新交付。")
                }
                status = "正在自動設定裝置憑證…"
                // No customer file picker or password entry.
                let handler = CertificateFileHandler(key: key, provision: profile, password: assets.password, nickname: nickname, isDefault: true)
                try await handler.copy()
                try await handler.addToDatabase()
                try Storage.shared.context.save()
                certificate = Storage.shared.getAllCertificates().first(where: { $0.nickname == nickname })
            }
            guard let certificate, !certificate.revoked else {
                throw failure("憑證已失效，請從訂單取得替換憑證。")
            }
            ready = true
            error = nil
            status = "裝置已就緒，選擇遊戲即可安裝"
        } catch {
            ready = false
            certificate = nil
            self.error = error.localizedDescription
            status = "裝置尚未就緒"
        }
    }

    func install(url: URL, expectedIdentifier: String, provenance: SourceAppProvenance?) async {
        guard !busy, installApp == nil else { return }
        if !ready { await prepare() }
        guard ready, let certificate else { return }
        guard !certificate.revoked, (certificate.expiration ?? .distantPast) > Date() else {
            ready = false
            error = "憑證已失效，請從訂單更新裝置安裝包。"
            return
        }
        guard url.scheme == "https", url.host == "uuxp.click", url.path.hasPrefix("/downloads/") else {
            error = "遊戲下載網址不屬於 UU 商店。"; return
        }
        busy = true
        error = nil
        defer { busy = false }
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            status = "正在下載遊戲，請保持 App 開啟…"
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            temporary = downloaded
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.host == "uuxp.click", response.url?.scheme == "https" else {
                throw failure("下載失敗，請稍後重試。")
            }
            let ipa = downloaded.appendingPathExtension("ipa")
            try FileManager.default.moveItem(at: downloaded, to: ipa)
            temporary = ipa
            status = "正在準備遊戲…"
            let handler = AppFileHandler(file: ipa, sourceProvenance: provenance)
            do {
                try await handler.copy()
                try await handler.extract()
                try await handler.move()
                try await handler.addToDatabase()
                try await handler.clean()
            } catch {
                try? await handler.clean()
                throw error
            }
            let importedRequest = Imported.fetchRequest()
            importedRequest.predicate = NSPredicate(format: "uuid == %@", handler.resultUUID)
            guard let imported = try Storage.shared.context.fetch(importedRequest).first,
                  imported.identifier == expectedIdentifier else {
                throw failure("遊戲檔案與商店項目不符，已停止安裝。")
            }
            if let expectedVersion = provenance?.sourceAppVersion, imported.version != expectedVersion {
                throw failure("遊戲檔案版本與商店不一致，請重新整理商店後再試。")
            }
            status = "正在自動簽署…"
            let signing = SigningHandler(app: imported, options: .defaultOptions)
            signing.appCertificate = certificate
            do {
                try await signing.copy()
                try await signing.modify()
                try await signing.clean()
            } catch {
                try? await signing.clean()
                throw error
            }
            let signedRequest = Signed.fetchRequest()
            signedRequest.predicate = NSPredicate(format: "uuid == %@", signing.resultUUID)
            guard let signed = try Storage.shared.context.fetch(signedRequest).first else {
                throw failure("無法取得簽署結果，請重試。")
            }
            // Present the exact signed result, never whichever app happens to be newest.
            installApp = AnyApp(base: signed)
            status = "請確認 iOS 安裝提示；安裝結果以裝置顯示為準"
        } catch {
            self.error = error.localizedDescription
            status = "安裝準備失敗，可重新嘗試"
        }
    }
}
