import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    
    // The OS only provides the total bytes received/sent since boot. So we use these to compare diff
    var lastRx: UInt64 = 0
    var lastTx: UInt64 = 0
    // Routers traffic back within computer. Used for localhost.
    var loopbackNetwork = "lo0"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        updateStatus()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateStatus()
        }
    }

    func updateStatus() {
        let (rx, tx) = getNetworkBytes()
        // Calc diff to get current speed, if rx or tx reset then start at 0 again
        let rxSpeed = rx >= lastRx ? rx - lastRx : 0
        let txSpeed = tx >= lastTx ? tx - lastTx : 0
        lastRx = rx
        lastTx = tx

        let rxStr = String(format: "%.0f", Double(rxSpeed)/1024)
        let txStr = String(format: "%.0f", Double(txSpeed)/1024)
        statusItem.button?.title = "↓ \(rxStr)KB ↑ \(txStr)KB"
    }

    func getNetworkBytes() -> (UInt64, UInt64) {
        // Sums all active interfaces (except lo0)
        var rxBytes: UInt64 = 0 // Receive count
        var txBytes: UInt64 = 0 // Transmit count
        
        // The getifaddrs() function creates a linked list of structs describing network interfaces
        // Returns pointer to first struct. We will loop & gather data. Then clean memory.

        // Grab pointer. Ensure non-null. Defer memory cleanup to guarantee it
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
                rxBytes += UInt64(networkData.ifi_ibytes)
                txBytes += UInt64(networkData.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }
        return (rxBytes, txBytes)
    }
}
