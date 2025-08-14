import Cocoa
import SwiftUI

enum UpdateMode {
    // Pause: freezes the current list
    case paused
    // Continuous: update in background & on menu open
    case continuous
    // On-demand: starts updating from a fresh list on menu open (less distracting)
    case onDemand
}

private let figureSpace = "\u{2007}"
private let loopbackNetwork = "lo0" // Exclude loopback (localhost)
private let maxLogEntries: Int = 20
private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    // Timers
    private var timer: Timer?            // background sampler (continuous mode)
    private var menuTimer: Timer?        // runs only while menu is open


    private var updateMode: UpdateMode = .continuous

    // Menu row backing + recent samples buffer
 
    private var recentSamples: [NetworkSample] = []
    private var menuRowItems: [NSMenuItem] = []

    // For on-demand/continuous delta math
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0


    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        configureMenu()
        setMode(.continuous)
    }


    // -- MENU --
    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        rebuildMenu(menu)
        statusItem.menu = menu
    }

    /// Rebuilds the static menu structure and installs 20 fixed rows we will retitle live.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.title = "Recent Traffic"
        header.isEnabled = false
        menu.addItem(header)

        // Fixed set of rows we can update in place while the menu is open.
        menuRowItems.removeAll()
        for _ in 0..<maxLogEntries {
            let row = NSMenuItem()
            row.isEnabled = false
            row.title = "-"
            menu.addItem(row)
            menuRowItems.append(row)
        }

        // Populate rows from whatever samples we have right now.
        updateMenuRowsFromSamples()

        menu.addItem(NSMenuItem.separator())

        let modeHeader = NSMenuItem()
        modeHeader.title = "Mode"
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        let pausedItem = NSMenuItem(title: "Paused", action: #selector(selectMode), keyEquivalent: "")
        pausedItem.target = self
        pausedItem.tag = 0
        pausedItem.state = (updateMode == .paused) ? .on : .off
        menu.addItem(pausedItem)

        let contItem = NSMenuItem(title: "Continuous Updates", action: #selector(selectMode), keyEquivalent: "")
        contItem.target = self
        contItem.tag = 1
        contItem.state = (updateMode == .continuous) ? .on : .off
        menu.addItem(contItem)

        let onDemandItem = NSMenuItem(title: "Update When Opened", action: #selector(selectMode), keyEquivalent: "")
        onDemandItem.target = self
        onDemandItem.tag = 2
        onDemandItem.state = (updateMode == .onDemand) ? .on : .off
        menu.addItem(onDemandItem)

                menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }


    // -- MODE --
    @objc private func selectMode(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: setMode(.paused)
        case 1: setMode(.continuous)
        case 2: setMode(.onDemand)
        default: break
        }
    }

    /// Switch the app's update mode and configure timers accordingly
    private func setMode(_ mode: UpdateMode) {
        updateMode = mode
        stopTimer()
        stopMenuTimer()
        switch mode {
        case .paused:
            statusItem.button?.title = "↓↑"
        case .continuous:
            startBackgroundTimer()
        case .onDemand:
            statusItem.button?.title = "↓↑"
        }
    }

    private func stopTimer() {
        // Stop the timer
        timer?.invalidate()
        timer = nil
    }

    // -- CONTINOUS MODE--

    private func startBackgroundTimer() {
        stopTimer()
        calibrateLastCounters()
        // Fire once a second and keep firing while the menu tracks.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateStatusContinuous()
        }
        // Run update status in a loop
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
        
        // Kick an immediate tick so UI isn’t empty at start.
        updateStatusContinuous()
    }

    private func updateStatusContinuous() {
        guard updateMode == .continuous else { return }
        let (rx, tx) = getNetworkBytes()
        let rxSpeed = rx &- lastRx
        let txSpeed = tx &- lastTx
        lastRx = rx
        lastTx = tx

        let rxStr = String(format: "%.0f", Double(rxSpeed) / 1024)
        let txStr = String(format: "%.0f", Double(txSpeed) / 1024)
        let padding = (3 - rxStr.count) + (3 - txStr.count)
        statusItem.button?.title = "\(String(repeating: figureSpace, count: padding < 0 ? 0 : padding))↓\(rxStr)KB ↑\(txStr)KB"



        appendSample(NetworkSample(
            timestamp: Date(),

            rxBytesPerSecond: rxSpeed,
            txBytesPerSecond: txSpeed
        ))
    }


    // -- MENU ONLY TIMER -- 
    private func startMenuTimer(sample: Bool) {
        stopMenuTimer()

        if sample {
            // On-demand: new list per open
            recentSamples.removeAll()
            calibrateLastCounters()
            // Prime first sample so the list isn't blank
            takeSample()
        }

        // Repeat every second; must fire while menu is tracking
        menuTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // In continuous mode we DO NOT sample here; background timer is already sampling.
            if self.updateMode == .onDemand && sample {
                self.takeSample()
            }

            self.updateMenuRowsFromSamples()
        }
        if let t = menuTimer { RunLoop.main.add(t, forMode: .common) }

        // Ensure rows are visible immediately
        updateMenuRowsFromSamples()
    }

    private func stopMenuTimer() {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    /// Take one sample and append to the rolling buffer.
    private func takeSample() {
        let (rx, tx) = getNetworkBytes()
        let rxSpeed = rx &- lastRx
        let txSpeed = tx &- lastTx
        lastRx = rx
        lastTx = tx
        appendSample(NetworkSample(
            timestamp: Date(),
            rxBytesPerSecond: rxSpeed,
            txBytesPerSecond: txSpeed
        ))
    }

    // MARK: - Samples & rows

    private func appendSample(_ sample: NetworkSample) {
        recentSamples.append(sample)
        if recentSamples.count > maxLogEntries {
            recentSamples.removeFirst(recentSamples.count - maxLogEntries)
        }
    }

    /// Refill the fixed 20 menu rows from the saved samples (newest first).
    private func updateMenuRowsFromSamples() {
        let latest = Array(recentSamples.suffix(maxLogEntries).reversed())
        for idx in 0..<maxLogEntries {
            let title: String
            if idx < latest.count {
                let s = latest[idx]
                let time = dateFormatter.string(from: s.timestamp)
                let down = formatBytesPerSecond(s.rxBytesPerSecond)
                let up   = formatBytesPerSecond(s.txBytesPerSecond)
                title = "\(time)  ↓ \(down)  ↑ \(up)"
            } else {
                title = "-"
            }
            if idx < menuRowItems.count {
                menuRowItems[idx].title = title
            }
        }
    }

    // -- Helpers --
    private func calibrateLastCounters() {
        // Avoid a spike on the first diff by aligning last counters to current OS totals.
        let (rx, tx) = getNetworkBytes()
        lastRx = rx
        lastTx = tx
    }

    private func formatBytesPerSecond(_ bytes: UInt64) -> String {
        return formatBytes(bytes) + "/s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 { return String(format: "%.0f %@", value, units[unitIndex]) }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    struct NetworkSample {
        let timestamp: Date
        let rxBytesPerSecond: UInt64
        let txBytesPerSecond: UInt64
    }

    // MARK: - Counters (per-interface totals)

    func getNetworkBytes() -> (UInt64, UInt64) {
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let ifa = current.pointee
            let flags = Int32(ifa.ifa_flags)
            if flags & IFF_UP == IFF_UP,
               let namePtr = ifa.ifa_name,
               String(cString: namePtr) != loopbackNetwork,
               let data = ifa.ifa_data {
                let networkData = data.load(as: if_data.self)
                rxBytes &+= UInt64(networkData.ifi_ibytes)
                txBytes &+= UInt64(networkData.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }
        return (rxBytes, txBytes)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Rebuild structure & paint current rows just before opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    /// Start/stop the menu-only timer exactly while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        switch updateMode {
        case .paused:
            // Show existing list; do not sample or refresh (rows already populated).
            stopMenuTimer()
        case .continuous:
            // Keep background sampling; just refresh rows once per second.
            startMenuTimer(sample: false)
        case .onDemand:
            // Begin a new list on open; sample while open.
            startMenuTimer(sample: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMenuTimer()
    }
}
