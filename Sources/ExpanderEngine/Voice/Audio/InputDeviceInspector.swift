import CoreAudio
import Foundation

/// Read-only questions about the system default input device, answered from the Core Audio HAL.
///
/// Capture never selects a device (`AVAudioEngine`'s input node follows the system default), so
/// the default input device is the one being recorded. The HAL properties are used rather than
/// `AUAudioUnit.deviceID`, whose `auAudioUnit` accessor is deprecated on macOS 27.
enum InputDeviceInspector {
    /// A wired or built-in input calls back within one 100–400 ms tap period (AVAudioNode.h).
    static let wiredInputStallSeconds: TimeInterval = 2.5
    /// Wireless and streaming inputs negotiate a profile before the first buffer. This bound is
    /// chosen, not measured: `DEVTYPE_HARDWARE_MIC_WIRELESS=1` runs the opt-in hardware test that
    /// would show a first buffer arriving later than this on a real headset.
    static let wirelessInputStallSeconds: TimeInterval = 6

    /// `AudioHardwareBase.h` transport types whose first buffer can lag a profile negotiation.
    /// Remote screen/streaming are spelled as four-char codes because they postdate the macOS 14
    /// SDK the release job builds with.
    static let slowStartTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeContinuityCaptureWireless,
        fourCharCode("rscr"),
        fourCharCode("rstr"),
    ]

    /// The stall bound for a transport; unknown or unreadable transports get the wired bound,
    /// so an unclassified device is never given longer to stay silent than a built-in mic.
    static func stallBound(forTransport transport: UInt32?) -> TimeInterval {
        guard let transport, slowStartTransports.contains(transport) else {
            return wiredInputStallSeconds
        }
        return wirelessInputStallSeconds
    }

    /// The stall bound for whatever input is the default right now.
    static func currentStallBound() -> TimeInterval {
        stallBound(forTransport: defaultInputDevice().flatMap(transportType(of:)))
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    static func transportType(of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    static func fourCharCode(_ code: StaticString) -> UInt32 {
        precondition(code.utf8CodeUnitCount == 4, "a four-char code has four ASCII bytes")
        return code.withUTF8Buffer { bytes in
            bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }
}
