import AppKit
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "Multitouch")

/// Raw trackpad contact frames, observed globally regardless of which app is
/// frontmost.
///
/// AppKit has no public route to this. `NSEvent` global monitors deliver
/// scroll events but strip their `NSTouch` payload entirely (measured: 156
/// scroll events, zero touches), and the responder-chain `touchesMoved(with:)`
/// path only fires while our panel is the key window — which is never the case
/// when the user is working in another app and swipes to a different Space.
/// A `CGEventTap` would need an Accessibility grant; this needs none.
///
/// So this reaches for MultitouchSupport, the same private framework the
/// established trackpad utilities use for exactly this reason. Everything is
/// resolved through `dlopen`/`dlsym` rather than linked, and the struct layout
/// is validated before it is trusted, so a future macOS that moves or removes
/// any of it degrades to `isAvailable == false` instead of crashing. Callers
/// are expected to keep a coarser fallback for that case.
@MainActor
final class MultitouchDevice {
    static let shared = MultitouchDevice()

    /// One trackpad contact, reduced to what swipe detection actually needs.
    struct Contact {
        let normalizedX: CGFloat
        let isTouching: Bool
    }

    /// Invoked on a background thread owned by MultitouchSupport — never the
    /// main actor. Kept behind a lock because it is written from the main actor
    /// in `start`/`stop` and read from that thread. Work inside it must stay
    /// small; it runs at trackpad frame rate.
    private let handlerLock = NSLock()
    nonisolated(unsafe) private var frameHandler: (([Contact]) -> Void)?

    private var devices: [MTDeviceRef] = []
    private var started = false

    private(set) var isAvailable = false

    private init() {}

    /// Resolve the framework and start every attached multitouch device.
    /// Idempotent; safe to call when unavailable.
    func start(onFrame: @escaping ([Contact]) -> Void) {
        guard !started else { return }
        handlerLock.withLock { frameHandler = onFrame }

        guard loadFramework() else { return }
        guard MTTouch.layoutMatchesFramework else {
            log.error("MultitouchSupport MTTouch layout changed — declining to parse contact frames")
            return
        }

        Self.activeInstance = self
        startDevices()
        started = true
        isAvailable = !devices.isEmpty

        if isAvailable {
            observeWake()
        } else {
            log.notice("No multitouch devices found")
        }
    }

    func stop() {
        for device in devices {
            MultitouchSymbols.shared?.deviceStop(device)
        }
        devices = []
        started = false
        isAvailable = false
        Self.activeInstance = nil
        handlerLock.withLock { frameHandler = nil }
    }

    // MARK: - Framework loading

    private func loadFramework() -> Bool {
        guard MultitouchSymbols.shared != nil else {
            log.notice("MultitouchSupport unavailable — falling back to coarser Space detection")
            return false
        }
        return true
    }

    private func startDevices() {
        guard let symbols = MultitouchSymbols.shared else { return }
        guard let list = symbols.createDeviceList() else { return }

        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = MTDeviceRef(mutating: raw)
            symbols.registerContactFrameCallback(device, multitouchContactCallback)
            symbols.deviceStart(device, 0)
            devices.append(device)
        }
    }

    /// MultitouchSupport stops delivering frames across sleep/wake. Re-arming
    /// the devices on wake keeps the gesture alive for the rest of the session.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                guard let symbols = MultitouchSymbols.shared else { return }
                for device in self.devices {
                    symbols.deviceStop(device)
                    symbols.registerContactFrameCallback(device, multitouchContactCallback)
                    symbols.deviceStart(device, 0)
                }
            }
        }
    }

    // MARK: - Callback plumbing

    /// `@convention(c)` callbacks cannot capture context, and MultitouchSupport
    /// offers no user-info parameter, so the live instance is reachable through
    /// this. Written once on the main actor during `start`.
    nonisolated(unsafe) fileprivate static var activeInstance: MultitouchDevice?

    /// Called on MultitouchSupport's own thread.
    fileprivate nonisolated func deliver(_ contacts: [Contact]) {
        handlerLock.lock()
        let handler = frameHandler
        handlerLock.unlock()
        handler?(contacts)
    }
}

// MARK: - Private framework surface

private typealias MTDeviceRef = UnsafeMutableRawPointer

private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

/// Trampoline out of the C callback and into the live instance.
private let multitouchContactCallback: MTContactCallback = { _, touches, numTouches, _, _ in
    guard let instance = MultitouchDevice.activeInstance,
          let touches, numTouches > 0 else { return 0 }

    let buffer = touches.assumingMemoryBound(to: MTTouch.self)
    var contacts: [MultitouchDevice.Contact] = []
    contacts.reserveCapacity(Int(numTouches))
    for index in 0..<Int(numTouches) {
        let touch = buffer[index]
        contacts.append(
            MultitouchDevice.Contact(
                normalizedX: CGFloat(touch.normalized.position.x),
                isTouching: touch.isTouching
            )
        )
    }
    instance.deliver(contacts)
    return 0
}

/// Lazily resolved MultitouchSupport entry points. `nil` when the framework or
/// any symbol is missing, which is the signal to fall back.
private final class MultitouchSymbols {
    static let shared: MultitouchSymbols? = MultitouchSymbols()

    typealias CreateDeviceList = @convention(c) () -> CFMutableArray?
    typealias RegisterCallback = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias DeviceRun = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias DeviceHalt = @convention(c) (MTDeviceRef) -> Void

    let createDeviceList: CreateDeviceList
    let registerContactFrameCallback: RegisterCallback
    let deviceStart: DeviceRun
    let deviceStop: DeviceHalt

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        guard
            let list = dlsym(handle, "MTDeviceCreateList"),
            let register = dlsym(handle, "MTRegisterContactFrameCallback"),
            let start = dlsym(handle, "MTDeviceStart"),
            let stop = dlsym(handle, "MTDeviceStop")
        else { return nil }

        createDeviceList = unsafeBitCast(list, to: CreateDeviceList.self)
        registerContactFrameCallback = unsafeBitCast(register, to: RegisterCallback.self)
        deviceStart = unsafeBitCast(start, to: DeviceRun.self)
        deviceStop = unsafeBitCast(stop, to: DeviceHalt.self)
    }
}

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// Mirrors MultitouchSupport's `MTTouch`. Field order and padding must match
/// the framework's own layout; `layoutMatchesFramework` is the tripwire.
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var pressure: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var reserved1: Int32
    var reserved2: Int32
    var density: Float

    /// The framework's struct is 96 bytes. If Swift's computed layout ever
    /// disagrees, every field read past `timestamp` would be garbage, so the
    /// caller declines to parse rather than acting on nonsense coordinates.
    static var layoutMatchesFramework: Bool {
        MemoryLayout<MTTouch>.stride == 96
    }

    /// States 3 (`MakeTouch`) and 4 (`Touching`) are the ones where a finger is
    /// actually down; the rest are hover, lift, and out-of-range transitions.
    var isTouching: Bool {
        state == 3 || state == 4
    }
}
