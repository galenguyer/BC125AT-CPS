import Foundation

/// Looks up the newest GitHub release and compares it with this build's version. It only
/// reports; updating is done by hand from the release page. One instance is shared by every
/// window and Settings, so hiding or skipping an update applies everywhere.
@MainActor @Observable
final class UpdateChecker {
    /// A newer release to tell the user about.
    struct Notice: Equatable {
        var version: String
        var page: URL
    }

    static let skippedVersionKey = "skippedUpdateVersion"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/galenguyer/BC125AT-CPS/releases/latest")!

    /// This build's version (MARKETING_VERSION), e.g. `1.1.0`.
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    private(set) var status = Status.idle
    /// Set by "Later": the notice stays hidden until the app is next launched.
    private(set) var hiddenForSession = false
    /// A version the user chose to skip. A later release is shown again.
    private(set) var skippedVersion = UserDefaults.standard.string(forKey: skippedVersionKey) ?? "" {
        didSet { UserDefaults.standard.set(skippedVersion, forKey: Self.skippedVersionKey) }
    }
    private var checkedThisLaunch = false

    /// The update to show in the window, unless it's been hidden or skipped.
    var notice: Notice? {
        guard case .available(let version, let page) = status, !hiddenForSession, version != skippedVersion else { return nil }
        return Notice(version: version, page: page)
    }

    func hideForSession() { hiddenForSession = true }

    func skip(_ version: String) { skippedVersion = version }

    /// Checks the first time it's called after launch; later calls do nothing.
    func checkOnce() async {
        guard !checkedThisLaunch else { return }
        checkedThisLaunch = true
        await check()
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking
        do {
            var request = URLRequest(url: Self.latestRelease)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: break
            case 404: status = .failed("No releases have been published yet."); return
            case let code: status = .failed("GitHub answered with HTTP \(code.map(String.init) ?? "?")."); return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            status = Self.isNewer(latest, than: Self.currentVersion)
                ? .available(version: latest, page: release.htmlURL)
                : .upToDate
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Compares dotted version numbers field by field, treating missing fields as 0, so `1.0`
    /// equals `1.0.0`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        var tagName: String
        var htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
