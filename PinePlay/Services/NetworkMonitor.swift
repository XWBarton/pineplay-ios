import Foundation
import Network
import Combine

@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published var offlineModeEnabled: Bool {
        didSet { UserDefaults.standard.set(offlineModeEnabled, forKey: "offlineModeEnabled") }
    }

    var isOffline: Bool { offlineModeEnabled || !isConnected }

    private let monitor = NWPathMonitor()

    private init() {
        offlineModeEnabled = UserDefaults.standard.bool(forKey: "offlineModeEnabled")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.pinepods.network"))
    }
}
