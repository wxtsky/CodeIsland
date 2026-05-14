import CoreBluetooth
import Foundation
import Observation
import os
import Security
import CodeIslandCore

/// Connection lifecycle state for the Buddy Bluetooth bridge.
enum ESP32BridgeStatus: Equatable {
    case off                  // user has disabled the bridge
    case poweredOff           // Bluetooth radio is off / unauthorized / unsupported
    case noSelection          // no Buddy has been selected yet
    case scanning             // discovery mode: enumerating nearby Buddies for the user
    case searchingSelected    // looking for the previously-selected Buddy
    case connecting           // found the selected one, connecting / discovering characteristics
    case pairing              // BLE connected, pair request sent, waiting for Buddy response
    case pairWaitingConfirm   // Buddy shows confirmation screen, waiting for user button press
    case pairRejected         // Buddy rejected pairing or pairing timed out
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
        case .pairing:            return "pairing"
        case .pairWaitingConfirm: return "confirm on Buddy"
        case .pairRejected:       return "pair rejected"
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
    private(set) var usesLegacyPairingFallback = false

    // Backoff table (seconds) mirrors Buddy's 1→2→4→8→…30 exponential.
    private static let reconnectBackoff: [Int] = [1, 2, 4, 8, 16, 30]

    /// Discovery entries older than this without a re-advertisement get pruned.
    private static let discoveryStaleSeconds: TimeInterval = 10

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var notifySubscriptionReady = false
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var discoveryActive = false
    private var discoveryPruneTimer: Timer?
    /// Stable 6-byte identifier for this Mac, used in the application-layer
    /// pairing handshake so Buddy can distinguish paired hosts.
    @ObservationIgnored
    private var hostIdentifier: Data = loadOrCreateHostId()
    /// Set to `true` inside `forgetSelection()` so the disconnect callback
    /// knows not to schedule a reconnect.
    private var forgetting = false
    /// Fires after `pairConfirmTimeoutSeconds` while Buddy is waiting for BOOT confirmation.
    private var pairTimeoutTimer: Timer?
    /// Fires when no pair response arrives at all, which indicates pre-pairing firmware.
    private var pairLegacyFallbackTimer: Timer?

    /// Callback fired when Buddy notifies a button press with a
    /// mascot `sourceId` byte. Nonisolated to allow CoreBluetooth delegate
    /// callbacks to forward to `@MainActor` consumers.
    var onFocusRequest: ((MascotID) -> Void)?

    /// Callback fired when Buddy sends a control opcode from a watch
    /// notification action.
    var onControlCommand: ((BuddyControlCommand) -> Void)?

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
        usesLegacyPairingFallback = false
        ensureCentral()
        attemptReconnectToSelected()
    }

    /// Disable the bridge, tear down peripheral + scan + discovery.
    func stop() {
        cancelReconnectTimer()
        cancelPairingTimers()
        stopDiscoveryInternal(updateStatus: false)
        if let central, central.isScanning { central.stopScan() }
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        notifySubscriptionReady = false
        connectedPeripheralName = nil
        usesLegacyPairingFallback = false
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
            if status != .connected,
               status != .connecting,
               status != .pairing,
               status != .pairWaitingConfirm {
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
        cancelPairingTimers()
        usesLegacyPairingFallback = false
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

    /// Forget the selected Buddy: send an unpair command so the Buddy clears
    /// its NVS, then disconnect and clear all persisted state.
    func forgetSelection() {
        cancelReconnectTimer()
        cancelPairingTimers()
        forgetting = true

        // Tell Buddy to clear its paired-host record before we drop the link.
        // Use .withResponse so we wait for the write ACK before disconnecting.
        if let peripheral, let writeChar,
           status == .connected || status == .pairing || status == .pairWaitingConfirm {
            let unpair = BuddyUnpairPayload(hostId: hostIdentifier)
            peripheral.writeValue(unpair.encode(), for: writeChar, type: .withResponse)
            Self.log.info("Sent unpair frame (withResponse), will disconnect on ACK")
            return
        }
        completeForget()
    }

    private func completeForget() {
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        notifySubscriptionReady = false
        connectedPeripheralName = nil
        usesLegacyPairingFallback = false
        selectedBuddyIdentifier = nil
        selectedBuddyName = nil
        defaults.removeObject(forKey: SettingsKey.selectedBuddyIdentifier)
        defaults.removeObject(forKey: SettingsKey.selectedBuddyName)
        if status != .off {
            status = .noSelection
        }
        forgetting = false
    }

    // MARK: - Public writes

    /// Write a single frame to Buddy. No-op when not connected.
    func send(_ frame: MascotFramePayload) {
        send(frame.encode())
    }

    /// Write a workspace update frame to Buddy. No-op when not connected.
    func sendWorkspace(_ workspace: BuddyWorkspacePayload) {
        send(workspace.encode())
    }

    /// Write a message preview frame to Buddy. No-op when not connected.
    func sendMessagePreview(_ preview: BuddyMessagePreviewPayload) {
        send(preview.encode())
    }

    /// Write model info frame to Buddy. No-op when not connected.
    func sendModel(_ model: BuddyModelPayload) {
        send(model.encode())
    }

    /// Write session stats frame to Buddy. No-op when not connected.
    func sendStats(_ stats: BuddyStatsPayload) {
        send(stats.encode())
    }

    /// Write subagent count frame to Buddy. No-op when not connected.
    func sendSubagent(_ subagent: BuddySubagentPayload) {
        send(subagent.encode())
    }

    /// Write event frame to Buddy. No-op when not connected.
    func sendEvent(_ event: BuddyEventPayload) {
        send(event.encode())
    }

    /// Write time hint frame to Buddy. No-op when not connected.
    func sendTimeHint(_ timeHint: BuddyTimeHintPayload) {
        send(timeHint.encode())
    }

    /// Write tool history entry frame to Buddy. No-op when not connected.
    func sendToolHistory(_ entry: BuddyToolHistoryPayload) {
        send(entry.encode())
    }

    /// Clear Buddy's tool history timeline. No-op when not connected.
    func sendToolHistoryClear() {
        send(BuddyToolHistoryClearPayload().encode())
    }

    private func send(_ data: Data) {
        guard let peripheral, let writeChar, status == .connected else { return }
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
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private static let hostIdDefaultsKey = "buddyHostIdentifier"

    /// Load or generate a stable 6-byte host identifier persisted in UserDefaults.
    private static func loadOrCreateHostId() -> Data {
        let defaults = UserDefaults.standard
        if let existing = defaults.data(forKey: hostIdDefaultsKey),
           existing.count == ESP32Protocol.hostIdLength {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: ESP32Protocol.hostIdLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            let uuid = UUID()
            let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            bytes = Array(uuidBytes.prefix(ESP32Protocol.hostIdLength))
        }
        let data = Data(bytes)
        defaults.set(data, forKey: hostIdDefaultsKey)
        return data
    }

    /// Send a pair request frame using the raw write characteristic.
    /// Called before `.connected` is reached, so we bypass the `send()` guard.
    private func sendPairRequest() {
        guard let peripheral, let writeChar else { return }
        let payload = BuddyPairRequestPayload(hostId: hostIdentifier)
        peripheral.writeValue(payload.encode(), for: writeChar, type: .withoutResponse)
        Self.log.info("Pair request sent")
        scheduleLegacyPairFallback()
    }

    private func scheduleLegacyPairFallback() {
        pairLegacyFallbackTimer?.invalidate()
        pairLegacyFallbackTimer = Timer.scheduledTimer(
            withTimeInterval: ESP32Protocol.pairLegacyFallbackSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLegacyPairFallback()
            }
        }
    }

    private func schedulePairTimeout() {
        pairTimeoutTimer?.invalidate()
        pairTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(ESP32Protocol.pairConfirmTimeoutSeconds),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePairTimeout()
            }
        }
    }

    private func cancelPairTimeout() {
        pairTimeoutTimer?.invalidate()
        pairTimeoutTimer = nil
    }

    private func cancelLegacyPairFallback() {
        pairLegacyFallbackTimer?.invalidate()
        pairLegacyFallbackTimer = nil
    }

    private func cancelPairingTimers() {
        cancelPairTimeout()
        cancelLegacyPairFallback()
    }

    private func handlePairTimeout() {
        guard status == .pairWaitingConfirm else { return }
        Self.log.error("Pair confirmation timed out after \(ESP32Protocol.pairConfirmTimeoutSeconds)s")
        pairTimeoutTimer = nil
        lastError = "Pairing was not completed. Press BOOT on Buddy to approve, or hold BOOT for 3s to reset pairing."
        status = .pairRejected
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func handleLegacyPairFallback() {
        guard status == .pairing else { return }
        Self.log.info("No pair response received; continuing in legacy Buddy firmware compatibility mode")
        pairLegacyFallbackTimer = nil
        usesLegacyPairingFallback = true
        lastError = nil
        status = .connected
        onConnected?()
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
            if peripheral != nil,
               status == .connected || status == .pairing || status == .pairWaitingConfirm || status == .connecting {
                // actively connected or mid-handshake — keep status
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
            self.usesLegacyPairingFallback = false
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
            self.cancelPairingTimers()
            self.lastError = error?.localizedDescription
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.notifySubscriptionReady = false
            self.connectedPeripheralName = nil
            self.scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            Self.log.info("Disconnected: \(error?.localizedDescription ?? "peer closed")")
            self.cancelPairingTimers()
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.notifySubscriptionReady = false
            self.connectedPeripheralName = nil
            if self.forgetting {
                // Link dropped during forget flow (write ACK may never arrive).
                // completeForget() is idempotent — safe even though peripheral
                // is already nil; it clears persisted selection + resets forgetting.
                self.completeForget()
            } else if self.selectedBuddyIdentifier == nil {
                if self.status != .off {
                    self.status = .noSelection
                }
            } else if self.status == .pairRejected {
                // Don't auto-reconnect after rejection; user must act.
            } else if self.status != .off {
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
                    guard ch.properties.contains(.notify) || ch.properties.contains(.indicate) else {
                        Self.log.error("Buddy uplink characteristic missing notify/indicate property")
                        self.lastError = "Buddy uplink characteristic is not subscribable"
                        return
                    }
                    self.notifyChar = ch
                    self.notifySubscriptionReady = false
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
            guard self.writeChar != nil, self.notifyChar != nil else {
                Self.log.error("Missing write or notify characteristic")
                self.lastError = "Device missing expected characteristics"
                return
            }
            Self.log.info("Buddy characteristics discovered; waiting for uplink subscription")
            self.lastError = nil
            self.status = .connecting
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == CBUUID(string: ESP32Protocol.notifyCharacteristicUUID) else {
                return
            }
            if let error {
                Self.log.error("didUpdateNotificationState error: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                self.notifySubscriptionReady = false
                return
            }
            guard characteristic.isNotifying else {
                Self.log.error("Buddy uplink subscription is not active")
                self.lastError = "Buddy uplink subscription is not active"
                self.notifySubscriptionReady = false
                return
            }
            guard !self.notifySubscriptionReady else { return }

            Self.log.info("Buddy uplink subscription enabled — initiating pair handshake")
            self.notifySubscriptionReady = true
            self.reconnectAttempt = 0
            self.lastError = nil
            if let live = peripheral.name, !live.isEmpty {
                self.connectedPeripheralName = live
                self.selectedBuddyName = live
                self.defaults.set(live, forKey: SettingsKey.selectedBuddyName)
            }
            self.status = .pairing
            self.sendPairRequest()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if self.forgetting {
                if let error {
                    Self.log.error("Unpair write ACK error (proceeding anyway): \(error.localizedDescription)")
                }
                self.completeForget()
            }
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
                  let event = BuddyUplinkEvent(payload: data) else {
                return
            }
            switch event {
            case .pairResponse(let response):
                self.handlePairResponse(response)
            case .focus(let mascot):
                Self.log.info("Button event: mascot=\(mascot.sourceName)")
                self.onFocusRequest?(mascot)
            case .command(let command):
                Self.log.info("Buddy control event: command=\(String(describing: command)) raw=\(command.rawValue)")
                self.onControlCommand?(command)
            }
        }
    }

    @MainActor
    private func handlePairResponse(_ response: BuddyPairResponse) {
        cancelLegacyPairFallback()
        switch response {
        case .accepted:
            Self.log.info("Pair accepted by Buddy")
            cancelPairTimeout()
            lastError = nil
            usesLegacyPairingFallback = false
            status = .connected
            onConnected?()
        case .rejected:
            Self.log.error("Pair rejected or not completed by Buddy")
            cancelPairTimeout()
            lastError = "Pairing was not completed. If Buddy is paired with another Mac, hold BOOT for 3s on Buddy to reset pairing."
            usesLegacyPairingFallback = false
            status = .pairRejected
            if let peripheral, let central {
                central.cancelPeripheralConnection(peripheral)
            }
        case .pending:
            Self.log.info("Pair pending — waiting for user confirmation on Buddy")
            lastError = nil
            usesLegacyPairingFallback = false
            status = .pairWaitingConfirm
            schedulePairTimeout()
        }
    }
}
