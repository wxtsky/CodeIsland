import CoreBluetooth
import Foundation
import Observation
import os
import CodeIslandCore

/// Connection lifecycle state for the Buddy Bluetooth bridge.
enum ESP32BridgeStatus: Equatable {
    case off                  // user has disabled the bridge
    case poweredOff           // Bluetooth radio is off / unauthorized / unsupported
    case noSelection          // no Buddy has been selected yet
    case scanning             // discovery mode: enumerating nearby Buddies for the user
    case searchingSelected    // looking for the previously-selected Buddy
    case connecting           // found the selected one, connecting / discovering characteristics
    case connected            // ready to write + receiving notifications
    case reconnecting(Int)    // seconds until next attempt to find the selected Buddy

    var shortDescription: String {
        switch self {
        case .off:                return "off"
        case .poweredOff:         return "bluetooth off"
        case .noSelection:        return "no selection"
        case .scanning:           return "scanning"
        case .searchingSelected:  return "searching selected"
        case .connecting:         return "connecting"
        case .connected:          return "connected"
        case .reconnecting(let s): return "reconnecting in \(s)s"
        }
    }
}

/// One Buddy peripheral seen during discovery.
struct DiscoveredBuddy: Identifiable, Equatable {
    let id: UUID            // CBPeripheral.identifier (stable per Mac)
    var name: String
    var rssi: Int
    var lastSeen: Date
}

/// CoreBluetooth central that talks to the Buddy LCD companion.
///
/// Supports discovering multiple nearby Buddies (each firmware now advertises
/// a unique `Buddy-XXXXXX` name based on its chipId) and lets the user pick
/// one. The chosen peripheral identifier is persisted to UserDefaults; the
/// bridge auto-reconnects to it on next launch (and ignores other Buddies
/// in range).
///
/// Writes use `.withoutResponse` to match the firmware's `WRITE_NR` property.
/// The notify characteristic delivers 1-byte button events carrying the
/// currently displayed mascot's `sourceId` – dispatched to
/// `ESP32FocusCoordinator`.
@MainActor
@Observable
final class ESP32BridgeManager: NSObject {
    static let shared = ESP32BridgeManager()

    private static let log = Logger(subsystem: "com.codeisland", category: "esp32-bridge")

    // Observable for SettingsView
    private(set) var status: ESP32BridgeStatus = .off
    private(set) var lastError: String?
    private(set) var connectedPeripheralName: String?
    private(set) var discovered: [DiscoveredBuddy] = []
    private(set) var selectedBuddyIdentifier: UUID?
    private(set) var selectedBuddyName: String?

    // Backoff table (seconds) mirrors Buddy's 1→2→4→8→…30 exponential.
    private static let reconnectBackoff: [Int] = [1, 2, 4, 8, 16, 30]

    /// Discovery entries older than this without a re-advertisement get pruned.
    private static let discoveryStaleSeconds: TimeInterval = 10

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var discoveryActive = false
    private var discoveryPruneTimer: Timer?

    /// Callback fired when Buddy notifies a button press with a
    /// mascot `sourceId` byte. Nonisolated to allow CoreBluetooth delegate
    /// callbacks to forward to `@MainActor` consumers.
    var onFocusRequest: ((MascotID) -> Void)?

    /// Callback fired right after `.connected` is reached, so the publisher
    /// can push the current frame immediately (don't wait for the next
    /// heartbeat tick).
    var onConnected: (() -> Void)?

    private let defaults = UserDefaults.standard

    private override init() {
        super.init()
        loadSelectionFromDefaults()
    }

    // MARK: - Public lifecycle

    /// Enable the bridge. Lazily creates the `CBCentralManager` (which triggers
    /// the system Bluetooth permission prompt on first run). When a Buddy has
    /// already been selected, auto-reconnects to it; otherwise sits in
    /// `.noSelection` waiting for the user to pick one from the settings page.
    func start() {
        guard status == .off else { return }
        lastError = nil
        ensureCentral()
        attemptReconnectToSelected()
    }

    /// Disable the bridge, tear down peripheral + scan + discovery.
    func stop() {
        cancelReconnectTimer()
        stopDiscoveryInternal(updateStatus: false)
        if let central, central.isScanning { central.stopScan() }
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        connectedPeripheralName = nil
        status = .off
    }

    /// Enter discovery mode: continuously scan for nearby Buddies and populate
    /// `discovered` so the settings UI can offer them as choices. Does NOT
    /// auto-connect – call `select(buddyId:)` to commit.
    func startDiscovery() {
        ensureCentral()
        guard let central else { return }
        discoveryActive = true
        if central.state == .poweredOn {
            // allowDuplicates so RSSI updates live in the UI.
            let serviceUUID = CBUUID(string: ESP32Protocol.serviceUUID)
            central.scanForPeripherals(withServices: [serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            Self.log.info("Discovery scan started")
            if status != .connected, status != .connecting {
                status = .scanning
            }
        }
        startDiscoveryPruneTimer()
    }

    /// Exit discovery mode. Returns the central to either a directed reconnect
    /// scan (if a Buddy is selected but not connected) or idle.
    func stopDiscovery() {
        stopDiscoveryInternal(updateStatus: true)
    }

    /// Persist the user's Buddy choice and (re)connect to it.
    func select(buddyId: UUID) {
        let entry = discovered.first(where: { $0.id == buddyId })
        selectedBuddyIdentifier = buddyId
        selectedBuddyName = entry?.name ?? selectedBuddyName
        defaults.set(buddyId.uuidString, forKey: SettingsKey.selectedBuddyIdentifier)
        if let n = selectedBuddyName {
            defaults.set(n, forKey: SettingsKey.selectedBuddyName)
        }

        // Tear down any current connection and try the new selection.
        cancelReconnectTimer()
        if let peripheral, let central, peripheral.identifier != buddyId {
            central.cancelPeripheralConnection(peripheral)
        }
        if peripheral?.identifier != buddyId {
            peripheral = nil
            writeChar = nil
            notifyChar = nil
            connectedPeripheralName = nil
        }
        reconnectAttempt = 0
        attemptReconnectToSelected()
    }

    /// Forget the selected Buddy: disconnect, clear persisted identifier,
    /// and stop reconnecting.
    func forgetSelection() {
        cancelReconnectTimer()
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        connectedPeripheralName = nil
        selectedBuddyIdentifier = nil
        selectedBuddyName = nil
        defaults.removeObject(forKey: SettingsKey.selectedBuddyIdentifier)
        defaults.removeObject(forKey: SettingsKey.selectedBuddyName)
        if status != .off {
            status = .noSelection
        }
    }

    // MARK: - Public writes

    /// Write a single frame to Buddy. No-op when not connected.
    func send(_ frame: MascotFramePayload) {
        guard let peripheral, let writeChar, status == .connected else { return }
        let data = frame.encode()
        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }

    /// Write Buddy screen brightness. No-op when not connected.
    func sendBrightness(percent: Double) {
        guard let peripheral, let writeChar, status == .connected else { return }
        let data = BuddyBrightnessPayload(percent: percent).encode()
        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }

    /// Write Buddy screen orientation. No-op when not connected.
    func sendScreenOrientation(_ orientation: BuddyScreenOrientation) {
        guard let peripheral, let writeChar, status == .connected else { return }
        let data = BuddyScreenOrientationPayload(orientation: orientation).encode()
        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }

    // MARK: - Internals

    private func ensureCentral() {
        if central == nil {
            // `queue: nil` = main queue, so delegate callbacks land on main.
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private func loadSelectionFromDefaults() {
        if let raw = defaults.string(forKey: SettingsKey.selectedBuddyIdentifier),
           !raw.isEmpty,
           let uuid = UUID(uuidString: raw) {
            selectedBuddyIdentifier = uuid
        }
        if let n = defaults.string(forKey: SettingsKey.selectedBuddyName), !n.isEmpty {
            selectedBuddyName = n
        }
    }

    /// Either retrieve the selected peripheral from the system cache and
    /// connect directly, or start a directed scan that will only connect when
    /// the matching identifier shows up.
    private func attemptReconnectToSelected() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            // CBCentralManagerDelegate.didUpdateState will retry once powered on.
            return
        }
        guard let target = selectedBuddyIdentifier else {
            // No selection — sit idle and let the user pick from discovery UI.
            if status != .connected, status != .connecting {
                status = .noSelection
            }
            return
        }

        // Clear the directed-scan reconnect timer; we'll re-arm if needed.
        cancelReconnectTimer()

        // Try to grab a cached peripheral handle and connect directly first.
        let cached = central.retrievePeripherals(withIdentifiers: [target])
        if let cachedPeripheral = cached.first {
            Self.log.info("Reconnecting to cached peripheral \(cachedPeripheral.name ?? "<unnamed>")")
            self.peripheral = cachedPeripheral
            cachedPeripheral.delegate = self
            connectedPeripheralName = cachedPeripheral.name ?? selectedBuddyName
            status = .connecting
            central.connect(cachedPeripheral, options: nil)
            return
        }

        // No cached handle: scan and wait for the right identifier.
        beginDirectedScan()
    }

    private func beginDirectedScan() {
        guard let central else { return }
        guard central.state == .poweredOn else { return }
        guard selectedBuddyIdentifier != nil else { return }
        if discoveryActive {
            // Discovery scan already running; didDiscover will gate by identifier.
            status = .searchingSelected
            return
        }
        let serviceUUID = CBUUID(string: ESP32Protocol.serviceUUID)
        central.scanForPeripherals(withServices: [serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = .searchingSelected
        Self.log.info("Directed scan for selected Buddy")
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func scheduleReconnect() {
        guard selectedBuddyIdentifier != nil else {
            status = .noSelection
            return
        }
        cancelReconnectTimer()
        let idx = min(reconnectAttempt, Self.reconnectBackoff.count - 1)
        let delay = Self.reconnectBackoff[idx]
        reconnectAttempt += 1
        status = .reconnecting(delay)
        Self.log.info("Scheduling reconnect in \(delay)s (attempt \(self.reconnectAttempt))")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.attemptReconnectToSelected()
            }
        }
    }

    private func stopDiscoveryInternal(updateStatus: Bool) {
        discoveryActive = false
        discoveryPruneTimer?.invalidate()
        discoveryPruneTimer = nil
        guard let central else { return }
        if central.isScanning {
            central.stopScan()
        }
        if updateStatus {
            // After leaving discovery, return to the appropriate state.
            if peripheral != nil, status == .connected {
                // already connected — keep status
            } else if selectedBuddyIdentifier != nil {
                attemptReconnectToSelected()
            } else if status != .off, status != .poweredOff {
                status = .noSelection
            }
        }
    }

    private func startDiscoveryPruneTimer() {
        discoveryPruneTimer?.invalidate()
        discoveryPruneTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneStaleDiscoveries()
            }
        }
    }

    private func pruneStaleDiscoveries() {
        let cutoff = Date().addingTimeInterval(-Self.discoveryStaleSeconds)
        let connectedId = peripheral?.identifier
        let filtered = discovered.filter { $0.lastSeen >= cutoff || $0.id == connectedId }
        if filtered.count != discovered.count {
            discovered = filtered
        }
    }

    fileprivate func updateDiscovery(peripheral: CBPeripheral, name: String?, rssi: Int) {
        // Only count peripherals whose names look like Buddies (or unnamed,
        // which can happen on first advertisement). Service-UUID scan filter
        // already restricts to our firmware.
        let resolvedName = name ?? peripheral.name ?? "Buddy"
        let now = Date()
        if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[idx].name = resolvedName
            discovered[idx].rssi = rssi
            discovered[idx].lastSeen = now
        } else {
            discovered.append(DiscoveredBuddy(
                id: peripheral.identifier,
                name: resolvedName,
                rssi: rssi,
                lastSeen: now
            ))
        }
        // Sort by RSSI descending (closer first); stable-ish ordering.
        discovered.sort { $0.rssi > $1.rssi }

        // If this happens to be the selected device and we're not yet
        // connected, kick off a connection.
        if let target = selectedBuddyIdentifier,
           peripheral.identifier == target,
           self.peripheral == nil {
            Self.log.info("Selected Buddy appeared in discovery; connecting")
            self.peripheral = peripheral
            peripheral.delegate = self
            connectedPeripheralName = resolvedName
            selectedBuddyName = resolvedName
            defaults.set(resolvedName, forKey: SettingsKey.selectedBuddyName)
            status = .connecting
            central?.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ESP32BridgeManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.lastError = nil
                if self.discoveryActive {
                    self.startDiscovery()
                } else {
                    self.attemptReconnectToSelected()
                }
            case .poweredOff:
                self.status = .poweredOff
                self.lastError = "Bluetooth is off"
            case .unauthorized:
                self.status = .poweredOff
                self.lastError = "Bluetooth permission denied"
            case .unsupported:
                self.status = .poweredOff
                self.lastError = "Bluetooth unsupported on this Mac"
            case .resetting:
                self.status = .poweredOff
                self.lastError = "Bluetooth is resetting"
            case .unknown:
                self.status = .poweredOff
            @unknown default:
                self.status = .poweredOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssiInt = RSSI.intValue
        Task { @MainActor in
            self.updateDiscovery(peripheral: peripheral, name: advName, rssi: rssiInt)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            Self.log.info("Connected, discovering services")
            // If discovery is still running we no longer need to scan once
            // we have the selected device hooked up.
            if !self.discoveryActive, central.isScanning {
                central.stopScan()
            }
            peripheral.discoverServices([CBUUID(string: ESP32Protocol.serviceUUID)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            Self.log.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
            self.lastError = error?.localizedDescription
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.connectedPeripheralName = nil
            self.scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            Self.log.info("Disconnected: \(error?.localizedDescription ?? "peer closed")")
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.connectedPeripheralName = nil
            if self.status != .off {
                self.scheduleReconnect()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ESP32BridgeManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                Self.log.error("discoverServices error: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                return
            }
            let target = CBUUID(string: ESP32Protocol.serviceUUID)
            guard let service = peripheral.services?.first(where: { $0.uuid == target }) else {
                Self.log.error("Target service missing from peripheral")
                self.lastError = "Service not found on device"
                return
            }
            peripheral.discoverCharacteristics([
                CBUUID(string: ESP32Protocol.writeCharacteristicUUID),
                CBUUID(string: ESP32Protocol.notifyCharacteristicUUID),
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                Self.log.error("discoverCharacteristics error: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                return
            }
            let writeUUID = CBUUID(string: ESP32Protocol.writeCharacteristicUUID)
            let notifyUUID = CBUUID(string: ESP32Protocol.notifyCharacteristicUUID)
            for ch in service.characteristics ?? [] {
                if ch.uuid == writeUUID {
                    self.writeChar = ch
                } else if ch.uuid == notifyUUID {
                    self.notifyChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
            guard self.writeChar != nil, self.notifyChar != nil else {
                Self.log.error("Missing write or notify characteristic")
                self.lastError = "Device missing expected characteristics"
                return
            }
            Self.log.info("Buddy ready")
            self.reconnectAttempt = 0
            self.status = .connected
            // Persist the live name in case it changed since selection.
            if let live = peripheral.name, !live.isEmpty {
                self.connectedPeripheralName = live
                self.selectedBuddyName = live
                self.defaults.set(live, forKey: SettingsKey.selectedBuddyName)
            }
            self.onConnected?()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                Self.log.error("didUpdateValue error: \(error.localizedDescription)")
                return
            }
            guard characteristic.uuid == CBUUID(string: ESP32Protocol.notifyCharacteristicUUID),
                  let data = characteristic.value,
                  let sourceId = data.first,
                  let mascot = MascotID(rawValue: sourceId) else {
                return
            }
            Self.log.info("Button event: mascot=\(mascot.sourceName)")
            self.onFocusRequest?(mascot)
        }
    }
}
