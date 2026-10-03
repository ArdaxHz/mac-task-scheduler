//
//  UpdateService.swift
//  MacScheduler
//
//  Checks for new releases on GitHub.
//

import Foundation

actor UpdateService {
    static let shared = UpdateService()

    private let repoOwner = "ArdaxHz"
    private let repoName = "mac-task-scheduler"

    struct Release {
        let tagName: String
        let version: String
        let htmlURL: String
        let publishedAt: Date?
        let body: String
    }

    /// Fetch the latest GitHub release and compare with the current app version.
    func checkForUpdate() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else {
                return nil
            }

            let remoteVersion = extractVersion(from: tagName)
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            guard isNewer(remote: remoteVersion, current: currentVersion) else {
                return nil
            }

            let body = json["body"] as? String ?? ""
            var publishedAt: Date?
            if let dateStr = json["published_at"] as? String {
                let formatter = ISO8601DateFormatter()
                publishedAt = formatter.date(from: dateStr)
            }

            return Release(
                tagName: tagName,
                version: remoteVersion,
                htmlURL: htmlURL,
                publishedAt: publishedAt,
                body: body
            )
        } catch {
            return nil
        }
    }

    /// Extract date-based version from a GitHub release tag.
    /// CI tags follow `v{MARKETING_VERSION}-{SHORT_SHA}`, e.g.:
    ///   "v2026.03.04-abc1234" → "2026.03.04"
    /// The trailing commit hash (7+ hex chars after the last dash) is stripped.
    private func extractVersion(from tag: String) -> String {
        var version = tag
        version = version.replacingOccurrences(of: "\"", with: "")
        if version.hasPrefix("v") { version = String(version.dropFirst()) }
        if let lastDash = version.lastIndex(of: "-") {
            let suffix = String(version[version.index(after: lastDash)...])
            let isCommitHash = suffix.count >= 7 && suffix.allSatisfy { $0.isHexDigit }
            if isCommitHash {
                version = String(version[..<lastDash])
            }
        }
        return version
    }

    /// Parse a version string into numeric components.
    /// e.g. "2026.03.04" → [2026, 3, 4]
    private func parseVersion(_ version: String) -> [Int] {
        let cleaned = version.replacingOccurrences(of: "\"", with: "")
        return cleaned.split(separator: ".").compactMap { Int($0) }
    }

    /// Compare date-based version strings (YYYY.MM.DD). Returns true if remote is newer.
    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = parseVersion(remote)
        let currentParts = parseVersion(current)

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}
