import AppKit
import CoreAudio
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "SystemVolume")

@MainActor
final class SystemVolumeManager: ObservableObject {
    static let shared = SystemVolumeManager()

    @Published var volume: Float = 0.5
    @Published var isMuted: Bool = false
    @Published var isHUDVisible: Bool = false

    private var defaultOutputDeviceID: AudioDeviceID = 0
    private var dismissWorkItem: DispatchWorkItem?
    private var isUpdatingInternally = false

    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refreshDefaultDevice()
        fetchCurrentVolume()
        installListeners()
    }

    // Refresh active default audio output device ID
    func refreshDefaultDevice() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        if status == noErr {
            self.defaultOutputDeviceID = deviceID
        }
    }

    // Read current scalar volume (0.0 to 1.0) and mute state
    func fetchCurrentVolume() {
        guard defaultOutputDeviceID != 0 else { return }

        // Fetch volume scalar
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var status = AudioObjectGetPropertyData(defaultOutputDeviceID, &volumeAddress, 0, nil, &size, &vol)
        if status != noErr {
            volumeAddress.mElement = 1
            status = AudioObjectGetPropertyData(defaultOutputDeviceID, &volumeAddress, 0, nil, &size, &vol)
        }
        if status == noErr {
            self.volume = max(0.0, min(1.0, vol))
        }

        // Fetch mute status
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(defaultOutputDeviceID, &muteAddress, 0, nil, &muteSize, &mute)
        if muteStatus == noErr {
            self.isMuted = (mute != 0)
        }
    }

    // Set system volume scalar and notify listeners
    func setVolume(_ newVolume: Float) {
        guard defaultOutputDeviceID != 0 else { return }
        let clamped = max(0.0, min(1.0, newVolume))
        isUpdatingInternally = true
        defer { isUpdatingInternally = false }

        var vol = clamped
        let size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(defaultOutputDeviceID, &volumeAddress, 0, nil, size, &vol)
        if status != noErr {
            volumeAddress.mElement = 1
            _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &volumeAddress, 0, nil, size, &vol)
            volumeAddress.mElement = 2
            _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &volumeAddress, 0, nil, size, &vol)
        }

        self.volume = clamped

        // Auto unmute if volume is increased while muted
        if isMuted && clamped > 0 {
            setMute(false)
        }

        presentHUD()
    }

    // Toggle mute state for the active audio device
    func toggleMute() {
        setMute(!isMuted)
    }

    func setMute(_ mute: Bool) {
        guard defaultOutputDeviceID != 0 else { return }
        var muteVal: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(defaultOutputDeviceID, &muteAddress, 0, nil, size, &muteVal)
        if status == noErr {
            self.isMuted = mute
            presentHUD()
        }
    }

    // Handle scroll wheel event over the notch area
    func handleScroll(event: NSEvent) -> Bool {
        let isEnabled = UserDefaults.standard.object(forKey: SettingsKey.notchScrollVolumeControl) as? Bool ?? SettingsDefaults.notchScrollVolumeControl
        guard isEnabled else { return false }

        // Only handle predominant vertical scroll
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }

        let delta: Float
        if event.hasPreciseScrollingDeltas {
            delta = Float(event.scrollingDeltaY) * 0.003
        } else {
            delta = event.deltaY > 0 ? 0.04 : -0.04
        }
        guard abs(delta) > 0.0001 else { return false }

        let previousVolume = self.volume
        let targetVolume = max(0.0, min(1.0, previousVolume + delta))
        setVolume(targetVolume)

        // Haptic feedback on boundary or progress
        if (targetVolume == 0.0 && previousVolume > 0.0) || (targetVolume == 1.0 && previousVolume < 1.0) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        return true
    }

    // Show temporary volume pill HUD
    private func presentHUD() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            self.isHUDVisible = true
        }
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.isHUDVisible = false
            }
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // Install CoreAudio listeners for device and volume changes
    private func installListeners() {
        // Default device listener
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDefaultDevice()
                self?.fetchCurrentVolume()
            }
        }
        defaultDeviceListenerBlock = devBlock
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            devBlock
        )

        // Volume scalar listener
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.isUpdatingInternally else { return }
                self.fetchCurrentVolume()
            }
        }
        volumeListenerBlock = volBlock
        _ = AudioObjectAddPropertyListenerBlock(
            defaultOutputDeviceID,
            &volumeAddress,
            DispatchQueue.main,
            volBlock
        )

        // Mute listener
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let mBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.isUpdatingInternally else { return }
                self.fetchCurrentVolume()
            }
        }
        muteListenerBlock = mBlock
        _ = AudioObjectAddPropertyListenerBlock(
            defaultOutputDeviceID,
            &muteAddress,
            DispatchQueue.main,
            mBlock
        )
    }
}
