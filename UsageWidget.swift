// Usage Widget — menu-bar monitor for Claude Code subscription limits.
//
// Reads Claude Code's OAuth tokens from the macOS Keychain (one entry per
// profile/config dir) and polls the same endpoint the in-app /usage screen
// uses, showing 5-hour and weekly window utilization in the menu bar.
//
// Run with --once to print usage to stdout and exit (for testing).

import Cocoa

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
// Usage windows only move on hour/day timescales, and this endpoint has its
// own (undocumented) rate limit. We adaptively poll (e.g. hourly by default,
// boosting to 2.5m on changes, then decaying to 5m -> 15m -> 30m -> 1h).
let warnThreshold = 80.0

// OAuth token refresh — standard public Claude Code OAuth client values.
let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

// MARK: - Models

struct WindowUsage {
    let utilization: Double
    let resetsAt: Date?
}

struct Credential {
    let service: String
    let token: String
    let expiresAt: Date
    let label: String
}

struct ProfileUsage {
    let label: String
    var fiveHour: WindowUsage?
    var sevenDay: WindowUsage?
    var error: String?
    // Set when the endpoint refuses with a rate limit (HTTP 429 / Retry-After).
    // Seconds to wait before polling again — drives a hard backoff so we stop
    // hammering the endpoint regardless of the adaptive activity cadence.
    var retryAfter: TimeInterval?
    var extraUsageCost: Double?
}

// MARK: - Menu bar stat selection

// Which stats the user has chosen to pin to the menu bar title (vs. only
// seeing them in the dropdown). Persisted across launches.
enum MenuBarStat: Int, CaseIterable {
    case fiveHourPct = 0
    case sevenDayPct = 1
    case fiveHourReset = 2
    case sevenDayReset = 3
    case extraCost = 4

    static let defaultsKey = "anchoredStats"

    static func loadAnchored() -> Set<MenuBarStat> {
        if let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] {
            return Set(raw.compactMap(MenuBarStat.init(rawValue:)))
        }
        return [.fiveHourPct, .sevenDayPct, .extraCost]  // matches the original layout + extra usage cost
    }

    static func save(_ stats: Set<MenuBarStat>) {
        UserDefaults.standard.set(stats.map { $0.rawValue }, forKey: defaultsKey)
    }
}

// MARK: - Shell / Keychain

func shell(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

var cachedServices: [String]?

func keychainServices() -> [String] {
    if let cached = cachedServices { return cached }
    guard let dump = shell(["security", "dump-keychain"]) else { return [] }
    var names = Set<String>()
    for line in dump.split(separator: "\n") {
        guard let r = line.range(of: "\"svce\"<blob>=\"") else { continue }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        let name = String(rest[..<end])
        if name.hasPrefix("Claude Code-credentials") { names.insert(name) }
    }
    let sorted = names.sorted()
    if !sorted.isEmpty { cachedServices = sorted }
    return sorted
}

// Like shell(), but returns combined stdout+stderr — needed for
// `security find-generic-password -g`, which prints attributes to stderr.
func shellCombined(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

// The keychain account ("acct") for a service, needed to update the right item.
func keychainAccount(_ service: String) -> String? {
    guard let dump = shellCombined(["security", "find-generic-password", "-s", service, "-g"]) else { return nil }
    for line in dump.split(separator: "\n") {
        guard let r = line.range(of: "\"acct\"<blob>=\"") else { continue }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        return String(rest[..<end])
    }
    return nil
}

// Updates the Keychain entry's password (the credential JSON) in place.
func writeKeychainCredential(service: String, account: String, json: String) -> Bool {
    return shell(["security", "add-generic-password", "-U", "-s", service, "-a", account, "-w", json]) != nil
}

// Exchanges a refresh token for a fresh access/refresh token pair.
// Returns the parsed JSON dict from the OAuth endpoint, or nil on failure.
func performTokenRefresh(refreshToken: String) -> [String: Any]? {
    var req = URLRequest(url: oauthTokenURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 15
    let payload: [String: Any] = [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": oauthClientID,
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    req.httpBody = bodyData

    let sem = DispatchSemaphore(value: 0)
    var respData: Data?
    var netError: Error?
    URLSession.shared.dataTask(with: req) { d, _, e in
        respData = d
        netError = e
        sem.signal()
    }.resume()
    sem.wait()

    guard netError == nil, let respData,
          let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
          obj["error"] == nil,
          obj["access_token"] is String,
          obj["refresh_token"] is String,
          (obj["expires_in"] as? Double) != nil
    else { return nil }
    return obj
}

func loadCredentials() -> [Credential] {
    var creds: [Credential] = []
    for svc in keychainServices() {
        guard let raw = shell(["security", "find-generic-password", "-s", svc, "-w"]),
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              var token = oauth["accessToken"] as? String,
              let expMs = oauth["expiresAt"] as? Double
        else { continue }
        var exp = Date(timeIntervalSince1970: expMs / 1000)

        // Expired or about to expire — self-refresh if we have a refresh token.
        if exp <= Date().addingTimeInterval(60),
           let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty {
            guard let result = performTokenRefresh(refreshToken: refreshToken),
                  let newToken = result["access_token"] as? String,
                  let newRefresh = result["refresh_token"] as? String,
                  let expiresIn = result["expires_in"] as? Double
            else { continue }  // refresh failed; skip this credential

            let newExpMs = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
            var updatedOauth = oauth
            updatedOauth["accessToken"] = newToken
            updatedOauth["refreshToken"] = newRefresh
            updatedOauth["expiresAt"] = newExpMs

            var updatedObj = obj
            updatedObj["claudeAiOauth"] = updatedOauth

            if let updatedData = try? JSONSerialization.data(withJSONObject: updatedObj),
               let updatedJSON = String(data: updatedData, encoding: .utf8),
               let account = keychainAccount(svc) {
                _ = writeKeychainCredential(service: svc, account: account, json: updatedJSON)
            }

            token = newToken
            exp = Date(timeIntervalSince1970: newExpMs / 1000)
        } else if exp <= Date() {
            continue  // expired and no usable refresh token; Claude Code refreshes it on next use
        }

        let sub = (oauth["subscriptionType"] as? String) ?? "profile"
        if sub.lowercased().contains("enterprise") || sub.lowercased().contains("api") {
            continue
        }
        let suffix = svc.replacingOccurrences(of: "Claude Code-credentials", with: "")
        let label = suffix.isEmpty ? sub : "\(sub) (\(suffix.dropFirst()))"
        creds.append(Credential(service: svc, token: token, expiresAt: exp, label: label))
    }
    // Most recently refreshed first — that's the profile currently in use.
    // We only keep the single newest one to prevent duplicate profiles and extra API requests.
    let sorted = creds.sorted { $0.expiresAt > $1.expiresAt }
    if let newest = sorted.first {
        return [newest]
    }
    return []
}

// MARK: - API

func parseISO(_ s: String) -> Date? {
    // resets_at carries 6-digit fractional seconds; strip them for ISO8601DateFormatter
    let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: stripped)
}

func parseWindow(_ obj: Any?) -> WindowUsage? {
    guard let d = obj as? [String: Any], let util = d["utilization"] as? Double else { return nil }
    return WindowUsage(utilization: util, resetsAt: (d["resets_at"] as? String).flatMap(parseISO))
}

func fetchUsage(_ cred: Credential) -> ProfileUsage {
    var result = ProfileUsage(label: cred.label)
    var req = URLRequest(url: usageURL)
    req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 10

    let sem = DispatchSemaphore(value: 0)
    var body: Data?
    var netError: Error?
    var status = 0
    var retryAfter: TimeInterval?
    URLSession.shared.dataTask(with: req) { d, r, e in
        body = d
        netError = e
        if let http = r as? HTTPURLResponse {
            status = http.statusCode
            if let ra = http.value(forHTTPHeaderField: "Retry-After"), let secs = Double(ra) {
                retryAfter = secs
            }
        }
        sem.signal()
    }.resume()
    sem.wait()

    if let e = netError {
        result.error = e.localizedDescription
        return result
    }
    if CommandLine.arguments.contains("--once"), let body, let jsonString = String(data: body, encoding: .utf8) {
        print("RAW JSON for \(cred.label): \(jsonString)")
    }
    let obj = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let apiMessage = (obj?["error"] as? [String: Any])?["message"] as? String

    // 429 (or an explicit Retry-After) means the endpoint is throttling us;
    // surface the status and trigger a hard backoff in the scheduler.
    if status == 429 || retryAfter != nil {
        result.retryAfter = retryAfter ?? 300  // default 5m cooldown if unspecified
        result.error = "rate-limited: \(apiMessage ?? "request not allowed right now")"
        return result
    }
    if status != 0 && status != 200 {
        result.error = "HTTP \(status): \(apiMessage ?? "request failed")"
        return result
    }
    if let apiMessage {
        result.error = apiMessage
        return result
    }
    guard let obj else {
        result.error = "unparseable response"
        return result
    }
    result.fiveHour = parseWindow(obj["five_hour"])
    result.sevenDay = parseWindow(obj["seven_day"])

    if let extraUsage = obj["extra_usage"] as? [String: Any],
       let usedCredits = extraUsage["used_credits"] as? Double {
        let decimalPlaces = (extraUsage["decimal_places"] as? Int) ?? 0
        result.extraUsageCost = usedCredits / pow(10.0, Double(decimalPlaces))
    }

    return result
}

// MARK: - Formatting

func pct(_ w: WindowUsage?) -> String {
    guard let w else { return "–" }
    return "\(Int(w.utilization.rounded()))%"
}

func resetsIn(_ w: WindowUsage?) -> String {
    guard let d = w?.resetsAt else { return "" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "resetting…" }
    let h = s / 3600
    let m = (s % 3600) / 60
    if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

// Compact countdown for the menu bar title, e.g. "2h14m", "3d12h", "14m".
func resetCountdownShort(_ w: WindowUsage?) -> String {
    guard let d = w?.resetsAt else { return "–" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "now" }
    let h = s / 3600
    let m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)d\(h % 24)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

func titleFragment(_ stat: MenuBarStat, _ p: ProfileUsage) -> String {
    switch stat {
    case .fiveHourPct: return pct(p.fiveHour)
    case .sevenDayPct: return "🇼\(pct(p.sevenDay))"
    case .fiveHourReset: return "⏳\(resetCountdownShort(p.fiveHour))"
    case .sevenDayReset: return "🇼⏳\(resetCountdownShort(p.sevenDay))"
    case .extraCost:
        if let cost = p.extraUsageCost, cost > 0, ((p.fiveHour?.utilization ?? 0) >= 100 || (p.sevenDay?.utilization ?? 0) >= 100) {
            return String(format: "💸$%.2f", cost)
        }
        return ""
    }
}

func statMenuTitle(_ stat: MenuBarStat, _ p: ProfileUsage) -> String {
    switch stat {
    case .fiveHourPct: return "5-hour usage: \(pct(p.fiveHour))"
    case .sevenDayPct: return "Weekly usage: \(pct(p.sevenDay))"
    case .fiveHourReset: return "5-hour \(resetsIn(p.fiveHour))"
    case .sevenDayReset: return "Weekly \(resetsIn(p.sevenDay))"
    case .extraCost:
        if let cost = p.extraUsageCost {
            return "Extra cost: \(String(format: "$%.2f", cost))"
        }
        return "Extra cost: $0.00"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastProfiles: [ProfileUsage] = []
    var anchored: Set<MenuBarStat> = MenuBarStat.loadAnchored()

    var lastUpdate: Date = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡…"
        refresh()
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.timerTicked()
        }
    }

    @objc func refresh() {
        refreshInternal(isManual: false)
    }

    @objc func manualRefresh() {
        refreshInternal(isManual: true)
    }

    private func refreshInternal(isManual: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let profiles = loadCredentials().map(fetchUsage)
            self?.logUsage(profiles)
            DispatchQueue.main.async {
                self?.lastUpdate = Date()
                self?.updateUI(profiles, isManual: isManual)
            }
        }
    }

    private func logUsage(_ profiles: [ProfileUsage]) {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let claudeDir = homeDir.appendingPathComponent(".claude")
        let logFile = claudeDir.appendingPathComponent("usage_log.jsonl")

        if !fileManager.fileExists(atPath: claudeDir.path) {
            try? fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        }

        let now = Date()
        let fmt = ISO8601DateFormatter()
        let timestampStr = fmt.string(from: now)

        for p in profiles {
            guard p.error == nil, let fiveHour = p.fiveHour, let sevenDay = p.sevenDay else { continue }

            var entry: [String: Any] = [
                "timestamp": timestampStr,
                "label": p.label,
                "five_hour_utilization": fiveHour.utilization,
                "seven_day_utilization": sevenDay.utilization
            ]

            if let resets5h = fiveHour.resetsAt {
                entry["five_hour_resets_at"] = fmt.string(from: resets5h)
            }
            if let resets7d = sevenDay.resetsAt {
                entry["seven_day_resets_at"] = fmt.string(from: resets7d)
            }
            if let cost = p.extraUsageCost {
                entry["extra_usage_cost"] = cost
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { continue }

            let line = jsonString + "\n"

            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                if let lineData = line.data(using: .utf8) {
                    fileHandle.write(lineData)
                }
            } else {
                try? line.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
    }

    func timerTicked() {
        let elapsed = Date().timeIntervalSince(lastUpdate)
        
        // If we are rate-limited, respect the cooldown period
        if let cooldown = lastProfiles.compactMap({ $0.retryAfter }).max(), elapsed < cooldown {
            updateUI(lastProfiles, isManual: false)
            return
        }
        
        let active = isCliRecentlyActive()
        if active || elapsed >= 3600 {
            refreshInternal(isManual: false)
        } else {
            updateUI(lastProfiles, isManual: false)
        }
    }

    func isCliRecentlyActive() -> Bool {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let claudeDir = homeDir.appendingPathComponent(".claude")
        let historyFile = claudeDir.appendingPathComponent("history.jsonl")
        let sessionsDir = claudeDir.appendingPathComponent("sessions")

        var checkURLs = [historyFile]

        if let contents = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            checkURLs.append(contentsOf: contents)
        }

        var mostRecent = Date.distantPast
        for url in checkURLs {
            if let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = resourceValues.contentModificationDate {
                if modDate > mostRecent {
                    mostRecent = modDate
                }
            }
        }

        let elapsed = Date().timeIntervalSince(mostRecent)
        print("[isCliRecentlyActive] Most recent file mod date: \(mostRecent), elapsed: \(elapsed)s")
        return elapsed < 600 // 10 minutes
    }

    func updateUI(_ profiles: [ProfileUsage], isManual: Bool = false) {
        let relevantProfiles = profiles.filter { p in
            return p.fiveHour != nil || p.sevenDay != nil || p.error != nil
        }

        print("[updateUI] isManual: \(isManual), profilesCount: \(relevantProfiles.count)")

        lastProfiles = relevantProfiles
        let menu = NSMenu()

        if relevantProfiles.isEmpty {
            statusItem.button?.title = "⚡ login?"
            menu.addItem(disabled("No fresh Claude Code token found"))
            menu.addItem(disabled("Open Claude Code once, then Refresh"))
        } else {
            let primaryIndex = relevantProfiles.firstIndex(where: { $0.fiveHour != nil }) ?? 0
            let primary = relevantProfiles[primaryIndex]
            let hasLimits = primary.fiveHour != nil || primary.sevenDay != nil
            let warn = [primary.fiveHour, primary.sevenDay]
                .compactMap { $0?.utilization }
                .contains { $0 >= warnThreshold }
            let statusIcon = warn ? "⚠️" : "⚡"

            if hasLimits {
                let order: [MenuBarStat] = [.fiveHourPct, .sevenDayPct, .fiveHourReset, .sevenDayReset, .extraCost]
                let fragments = order.filter { anchored.contains($0) }.map { titleFragment($0, primary) }.filter { !$0.isEmpty }
                statusItem.button?.title = fragments.isEmpty ? statusIcon : "\(statusIcon) " + fragments.joined(separator: " · ")
            } else {
                statusItem.button?.title = statusIcon
            }

            for (idx, p) in relevantProfiles.enumerated() {
                menu.addItem(disabled(p.label.uppercased()))
                if let err = p.error {
                    menu.addItem(disabled("  error: \(err)"))
                } else if idx == primaryIndex {
                    menu.addItem(disabled("  pin to menu bar:"))
                    for stat in MenuBarStat.allCases {
                        let item = NSMenuItem(title: statMenuTitle(stat, p), action: #selector(toggleStat(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = stat.rawValue
                        item.state = anchored.contains(stat) ? .on : .off
                        menu.addItem(item)
                    }
                } else {
                    menu.addItem(disabled("  5-hour:  \(pct(p.fiveHour))   \(resetsIn(p.fiveHour))"))
                    menu.addItem(disabled("  weekly:  \(pct(p.sevenDay))   \(resetsIn(p.sevenDay))"))
                    if let cost = p.extraUsageCost, cost > 0, ((p.fiveHour?.utilization ?? 0) >= 100 || (p.sevenDay?.utilization ?? 0) >= 100) {
                        menu.addItem(disabled("  extra cost: \(String(format: "$%.2f", cost))"))
                    }
                }
                menu.addItem(.separator())
            }
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        let intervalStr = isCliRecentlyActive() ? "1m" : "1h"
        menu.addItem(disabled("Updated \(fmt.string(from: lastUpdate)) · auto-refreshes every \(intervalStr)"))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func toggleStat(_ sender: NSMenuItem) {
        guard let stat = MenuBarStat(rawValue: sender.tag) else { return }
        if anchored.contains(stat) {
            anchored.remove(stat)
        } else {
            anchored.insert(stat)
        }
        MenuBarStat.save(anchored)
        updateUI(lastProfiles)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--once") {
    let delegate = AppDelegate()
    _ = delegate.isCliRecentlyActive()
    let creds = loadCredentials()
    if creds.isEmpty {
        print("No fresh Claude Code credentials found in Keychain.")
        exit(1)
    }
    let relevantProfiles = creds.map(fetchUsage).filter { p in
        return p.fiveHour != nil || p.sevenDay != nil || p.error != nil
    }
    if relevantProfiles.isEmpty {
        print("No profiles with rolling limits found.")
        exit(0)
    }
    for p in relevantProfiles {
        if let err = p.error {
            print("\(p.label): error — \(err)")
        } else {
            var out = "\(p.label): 5h \(pct(p.fiveHour)) (\(resetsIn(p.fiveHour))), weekly \(pct(p.sevenDay)) (\(resetsIn(p.sevenDay)))"
            if let cost = p.extraUsageCost, cost > 0 {
                out += String(format: ", extra cost: $%.2f", cost)
            }
            print(out)
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
app.run()
