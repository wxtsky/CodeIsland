import CoreBluetooth
import Foundation
import Observation
import os
import CodeIslandCore

/// Connection lifecycle state for the Buddy Bluetooth bridge.
enum ESP32BridgeStatus: Equatable {
    case off                  // user has disabled the bridge
    case poweredOff           // Bluetooth radio is off / unauthorized / unsupported
    case scanning             // looking for a Buddy peripheral
    case connecting           // found one, connecting / discovering characteristics
    case connected            // ready to write + receiving notifications
    case reconnecting(Int)    // seconds until next scan attempt

    var shortDescription: String {
        switch self {
        case .off:                return "off"
        case .poweredOff:         return "bluetooth off"
        case .scanning:           return "scanning"
        case .connecting:         return "connecting"
        case .connected:          return "connected"
        case .reconnecting(let s): return "reconnecting in \(s)s"
        }
    }
}

/// CoreBluetooth central that talks to the Buddy LCD companion.
///
/// Single peripheral assumption (first match wins). Writes use
/// `.withoutResponse` to match the firmware's `WRITE_NR` property.
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

    // Backoff table (seconds) mirrors Buddy's 1→2→4→8→…30 exponential.
    private static let reconnectBackoff: [Int] = [1, 2, 4, 8, 16, 30]

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?

    /// Callback fired when Buddy notifies a button press with a
    /// mascot `sourceId` byte. Nonisolated to allow CoreBluetooth delegate
    /// callbacks to forward to `@MainActor` consumers.
    var onFocusRequest: ((MascotID) -> Void)?

    /// Callback fired right after `.connected` is reached, so the publisher
    /// can push the current frame immediately (don't wait for the next
    /// heartbeat tick).
    var onConnected: (() -> Void)?

    private override init() {
        super.init()
    }

    /// Enable the bridge. Lazily creates the `CBCentralManager` (which triggers
    /// the system Bluetooth permission prompt on first run).
    func start() {
        guard status == .off else { return }
        lastError = nil
        status = .scanning
        if central == nil {
            // `queue: nil` = main queue, so delegate callbacks land on main.
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            beginScanIfPossible()
        }
    }

    /// Disable the bridge, tear down peripheral + scan.
    func stop() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempt = 0
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

    // MARK: - Internals

    private func beginScanIfPossible() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            Self.log.debug("beginScanIfPossible: central not powered on (\(String(describing: central.state.rawValue)))")
            return
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        Self.log.info("Scanning for Buddy peripheral")
        let serviceUUID = CBUUID(string: ESP32Protocol.serviceUUID)
        central.scanForPeripherals(withServices: [serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = .scanning
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let idx = min(reconnectAttempt, Self.reconnectBackoff.count - 1)
        let delay = Self.reconnectBackoff[idx]
        reconnectAttempt += 1
        status = .reconnecting(delay)
        Self.log.info("Scheduling reconnect in \(delay)s (attempt \(self.reconnectAttempt))")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginScanIfPossible()
            }
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
                self.beginScanIfPossible()
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
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            Self.log.info("Discovered peripheral \(peripheral.name ?? "<unnamed>") rssi=\(RSSI.intValue)")
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            self.status = .connecting
            self.connectedPeripheralName = peripheral.name
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            Self.log.info("Connected, discovering services")
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
