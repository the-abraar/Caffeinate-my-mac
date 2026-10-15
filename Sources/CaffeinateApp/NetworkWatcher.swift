import Network

/// Online/offline, and whether the Mac is on an iPhone hotspot. Reading the Wi-Fi name needs
/// Location permission, so this uses what the path already says: macOS marks Personal Hotspot
/// (Wi-Fi or USB) as expensive, and the iPhone's gateway is always 172.20.10.1.
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    private(set) var onHotspot = false
    var onChange: (() -> Void)?

    static func isHotspot(online: Bool, expensive: Bool, gateways: [String]) -> Bool {
        online && (expensive || gateways.contains("172.20.10.1"))
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let gateways = path.gateways.compactMap { endpoint -> String? in
                if case let .hostPort(host, _) = endpoint { return "\(host)" }
                return nil
            }
            isOnline = path.status == .satisfied
            onHotspot = Self.isHotspot(online: isOnline, expensive: path.isExpensive, gateways: gateways)
            onChange?()
        }
        monitor.start(queue: .main)
    }
}
