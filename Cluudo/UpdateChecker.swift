import AppKit
import UserNotifications

@MainActor
final class UpdateChecker {

    private let repoOwner   = "yurastegny"
    private let repoName    = "cluudo"
    private let releasesURL = URL(string: "https://github.com/yurastegny/cluudo/releases/latest")!

    private(set) var availableVersion: String?
    var onUpdateAvailable: ((String) -> Void)?

    func check() {
        Task { await fetchLatestRelease() }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releasesURL)
    }

    // MARK: - Private

    private func fetchLatestRelease() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cluudo/1.0",                  forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release   = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return }

        let remote  = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        guard isNewer(remote, than: current) else { return }

        availableVersion = remote
        onUpdateAvailable?(remote)
        notifyIfPermitted(version: remote)
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    private func notifyIfPermitted(version: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in self.sendNotification(version: version) }
        }
    }

    private func sendNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title    = "Cluudo \(version) is available"
        content.body     = "Click to open the download page."
        content.sound    = .default
        content.userInfo = ["action": "openReleases"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "cluudo-update-\(version)", content: content, trigger: nil)
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
}
