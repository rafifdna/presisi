import Cocoa
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusMenuItem: NSMenuItem!
    private var latencyMenuItem: NSMenuItem!
    private var interfaceMenuItem: NSMenuItem!
    private var lastCheckMenuItem: NSMenuItem!

    // MARK: - Networking
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.presisi.netmonitor.path")
    private var latencyTimer: Timer?

    // MARK: - State
    private var isOnline = false
    private var currentInterface = "—"

    // MARK: - Config (overridable via a Jamf Configuration Profile / managed prefs)
    // UserDefaults.standard automatically surfaces managed (forced) values that a
    // configuration profile writes to the app's bundle-ID domain.
    private let defaults = UserDefaults.standard

    private var monitorHost: String {
        defaults.string(forKey: "MonitorHost") ?? "1.1.1.1"
    }
    private var monitorPort: UInt16 {
        let v = defaults.integer(forKey: "MonitorPort")
        return v > 0 ? UInt16(v) : 443
    }
    private var checkInterval: TimeInterval {
        let v = defaults.integer(forKey: "CheckIntervalSeconds")
        return v > 0 ? TimeInterval(v) : 10
    }
    private var warnLatencyMs: Double {
        let v = defaults.integer(forKey: "WarnLatencyMs")
        return v > 0 ? Double(v) : 150
    }
    private var criticalLatencyMs: Double {
        let v = defaults.integer(forKey: "CriticalLatencyMs")
        return v > 0 ? Double(v) : 300
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        startPathMonitor()
        startLatencyTimer()
        checkLatency() // run an immediate first check
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor.cancel()
        latencyTimer?.invalidate()
    }

    // MARK: - Setup
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
    }

    private func setupMenu() {
        statusMenuItem    = NSMenuItem(title: "Status: checking…", action: nil, keyEquivalent: "")
        latencyMenuItem   = NSMenuItem(title: "Latency: —",        action: nil, keyEquivalent: "")
        interfaceMenuItem = NSMenuItem(title: "Interface: —",      action: nil, keyEquivalent: "")
        lastCheckMenuItem = NSMenuItem(title: "Last check: —",     action: nil, keyEquivalent: "")

        menu.addItem(statusMenuItem)
        menu.addItem(latencyMenuItem)
        menu.addItem(interfaceMenuItem)
        menu.addItem(lastCheckMenuItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        // Remove this item if you want to prevent users from quitting a managed deployment.
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Reachability (instant up/down + interface type)
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online = path.status == .satisfied
            var iface = "Unknown"
            if path.usesInterfaceType(.wifi)              { iface = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet){ iface = "Ethernet" }
            else if path.usesInterfaceType(.cellular)     { iface = "Cellular" }
            else if path.usesInterfaceType(.other)        { iface = "Other" }

            DispatchQueue.main.async {
                self.isOnline = online
                self.currentInterface = online ? iface : "—"
                if !online {
                    self.render(latencyMs: nil, online: false)
                } else {
                    self.checkLatency()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Latency
    private func startLatencyTimer() {
        latencyTimer?.invalidate()
        latencyTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkLatency()
        }
    }

    @objc private func checkNow() { checkLatency() }

    private func checkLatency() {
        guard isOnline else {
            render(latencyMs: nil, online: false)
            return
        }
        measureTCPLatency(host: monitorHost, port: monitorPort, timeout: 5) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ms): self?.render(latencyMs: ms, online: true)
                case .failure:         self?.render(latencyMs: nil, online: false)
                }
            }
        }
    }

    /// Measures the time to establish a TCP connection (a practical latency signal).
    private func measureTCPLatency(host: String,
                                   port: UInt16,
                                   timeout: TimeInterval,
                                   completion: @escaping (Result<Double, Error>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(NSError(domain: "netmonitor", code: -1, userInfo: nil)))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = DispatchTime.now()
        var finished = false

        let finish: (Result<Double, Error>) -> Void = { result in
            if finished { return }
            finished = true
            connection.cancel()
            completion(result)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                finish(.success(Double(elapsedNs) / 1_000_000.0))
            case .failed(let error):
                finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: monitorQueue)

        // Timeout guard
        monitorQueue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(NSError(domain: "netmonitor", code: -2, userInfo: nil)))
        }
    }

    // MARK: - Rendering
    private func render(latencyMs: Double?, online: Bool) {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

        guard online, let ms = latencyMs else {
            statusItem.button?.attributedTitle = coloredTitle(dot: "●", color: .systemRed, text: "Offline")
            statusMenuItem.title    = "Status: Offline"
            latencyMenuItem.title   = "Latency: —"
            interfaceMenuItem.title = "Interface: \(currentInterface)"
            lastCheckMenuItem.title = "Last check: \(now)"
            return
        }

        let color: NSColor
        if ms >= criticalLatencyMs      { color = .systemRed }
        else if ms >= warnLatencyMs     { color = .systemYellow }
        else                            { color = .systemGreen }

        let rounded = Int(ms.rounded())
        statusItem.button?.attributedTitle = coloredTitle(dot: "●", color: color, text: "\(rounded) ms")
        statusMenuItem.title    = "Status: Online"
        latencyMenuItem.title   = "Latency: \(rounded) ms  (\(monitorHost))"
        interfaceMenuItem.title = "Interface: \(currentInterface)"
        lastCheckMenuItem.title = "Last check: \(now)"
    }

    private func coloredTitle(dot: String, color: NSColor, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: dot + " ", attributes: [.foregroundColor: color]))
        result.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuBarFont(ofSize: 0)
        ]))
        return result
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
