// Claude Usage Widget — menu-bar monitor for Claude Code subscription limits.
//
// Reads Claude Code's OAuth tokens from the macOS Keychain (one entry per
// profile/config dir) and polls the same endpoint the in-app /usage screen
// uses, showing 5-hour and weekly window utilization in the menu bar.
//
// Run with --once to print usage to stdout and exit (for testing).

import Cocoa

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let refreshInterval: TimeInterval = 60
let warnThreshold = 80.0

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

func loadCredentials() -> [Credential] {
    var creds: [Credential] = []
    for svc in keychainServices() {
        guard let raw = shell(["security", "find-generic-password", "-s", svc, "-w"]),
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              let expMs = oauth["expiresAt"] as? Double
        else { continue }
        let exp = Date(timeIntervalSince1970: expMs / 1000)
        guard exp > Date() else { continue }  // stale token; Claude Code refreshes it on next use
        let sub = (oauth["subscriptionType"] as? String) ?? "profile"
        let suffix = svc.replacingOccurrences(of: "Claude Code-credentials", with: "")
        let label = suffix.isEmpty ? sub : "\(sub) (\(suffix.dropFirst()))"
        creds.append(Credential(service: svc, token: token, expiresAt: exp, label: label))
    }
    // Most recently refreshed first — that's the profile currently in use
    return creds.sorted { $0.expiresAt > $1.expiresAt }
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
    URLSession.shared.dataTask(with: req) { d, _, e in
        body = d
        netError = e
        sem.signal()
    }.resume()
    sem.wait()

    if let e = netError {
        result.error = e.localizedDescription
        return result
    }
    guard let body,
          let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    else {
        result.error = "unparseable response"
        return result
    }
    if let err = obj["error"] as? [String: Any] {
        result.error = (err["message"] as? String) ?? "API error"
        return result
    }
    result.fiveHour = parseWindow(obj["five_hour"])
    result.sevenDay = parseWindow(obj["seven_day"])
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡…"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let profiles = loadCredentials().map(fetchUsage)
            DispatchQueue.main.async { self.updateUI(profiles) }
        }
    }

    func updateUI(_ profiles: [ProfileUsage]) {
        let menu = NSMenu()

        if profiles.isEmpty {
            statusItem.button?.title = "⚡ login?"
            menu.addItem(disabled("No fresh Claude Code token found"))
            menu.addItem(disabled("Open Claude Code once, then Refresh"))
        } else {
            // Prefer a profile that actually has windowed limits (enterprise/API plans return none)
            let primary = profiles.first(where: { $0.fiveHour != nil }) ?? profiles[0]
            let warn = [primary.fiveHour, primary.sevenDay]
                .compactMap { $0?.utilization }
                .contains { $0 >= warnThreshold }
            statusItem.button?.title = "\(warn ? "⚠️" : "⚡")\(pct(primary.fiveHour)) · 🇼\(pct(primary.sevenDay))"

            for p in profiles {
                menu.addItem(disabled(p.label.uppercased()))
                if let err = p.error {
                    menu.addItem(disabled("  error: \(err)"))
                } else if p.fiveHour == nil && p.sevenDay == nil {
                    menu.addItem(disabled("  no rolling limits on this plan"))
                } else {
                    menu.addItem(disabled("  5-hour:  \(pct(p.fiveHour))   \(resetsIn(p.fiveHour))"))
                    menu.addItem(disabled("  weekly:  \(pct(p.sevenDay))   \(resetsIn(p.sevenDay))"))
                }
                menu.addItem(.separator())
            }
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        menu.addItem(disabled("Updated \(fmt.string(from: Date())) · auto-refreshes every \(Int(refreshInterval))s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--once") {
    let creds = loadCredentials()
    if creds.isEmpty {
        print("No fresh Claude Code credentials found in Keychain.")
        exit(1)
    }
    for p in creds.map(fetchUsage) {
        if let err = p.error {
            print("\(p.label): error — \(err)")
        } else if p.fiveHour == nil && p.sevenDay == nil {
            print("\(p.label): no rolling limits on this plan")
        } else {
            print("\(p.label): 5h \(pct(p.fiveHour)) (\(resetsIn(p.fiveHour))), weekly \(pct(p.sevenDay)) (\(resetsIn(p.sevenDay)))")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
app.run()
