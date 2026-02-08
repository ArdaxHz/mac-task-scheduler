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
    private let repoName = "mac-scheduler"

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

    /// Extract semver from tag like "v1.2.0-abc1234" → "1.2.0"
    private func extractVersion(from tag: String) -> String {
        var version = tag
        if version.hasPrefix("v") { version = String(version.dropFirst()) }
        // Strip anything after a dash (commit hash suffix)
        if let dashIndex = version.firstIndex(of: "-") {
            version = String(version[..<dashIndex])
        }
        return version
    }

    /// Compare semver strings. Returns true if remote is newer than current.
    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}
