import CoreAudio
import Foundation

public struct VolumeState: Equatable, Sendable {
    public let deviceID: UInt32
    public let deviceName: String?
    /// Nil means this output device does not expose a complete volume control.
    public let volumePercent: Int?
    /// Nil means this output device does not expose a complete mute control.
    public let isMuted: Bool?

    public init(deviceID: UInt32, deviceName: String? = nil, volumePercent: Int?, isMuted: Bool?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.volumePercent = volumePercent
        self.isMuted = isMuted
    }
}

public struct SystemVolumeResult: Equatable, Sendable {
    public let before: VolumeState
    public let after: VolumeState
    public var changed: Bool { before != after }

    public init(before: VolumeState, after: VolumeState) {
        self.before = before
        self.after = after
    }
}

public enum SystemVolumeError: Error, Equatable, LocalizedError, Sendable {
    case invalidPercent
    case noOutputDevice
    case unsupportedVolume
    case unsupportedMute
    case invalidDeviceValue
    case readFailed(Int32)
    case writeFailed(Int32)
    case verificationFailed
    case outputDeviceChanged

    public var errorDescription: String? {
        switch self {
        case .invalidPercent:
            return "音量必须是 0 到 100 的百分比，调节幅度不能超过 100 个百分点。"
        case .noOutputDevice:
            return "没有可用的系统输出设备。"
        case .unsupportedVolume:
            return "当前输出设备不支持 macOS 系统音量调节。HDMI 或数字输出请使用显示器或音箱自身音量，也可以切换到支持调节的输出设备。"
        case .unsupportedMute:
            return "当前输出设备不支持系统静音控制，请在设备上操作。"
        case .invalidDeviceValue:
            return "输出设备返回了无效的音量状态，暂时无法操作。"
        case .readFailed:
            return "无法读取系统音量，请检查当前输出设备后重试。"
        case .writeFailed:
            return "系统音量操作失败，请检查当前输出设备后重试。"
        case .verificationFailed:
            return "设备没有确认音量变化，请检查系统声音设置。"
        case .outputDeviceChanged:
            return "输出设备刚刚切换了，请重新说一次音量指令。"
        }
    }
}

struct SystemVolumeAudioProperty: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case volume, mute }
    let kind: Kind
    let channel: UInt32

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kind == .volume ? kAudioDevicePropertyVolumeScalar : kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
    }
}

/// The controller's only boundary with CoreAudio, allowing tests to exercise
/// unsupported hardware, failed writes and read-back without changing the Mac.
@MainActor
protocol SystemVolumeAudioBackend {
    func defaultOutputDevice() throws -> UInt32
    func outputDeviceName(on device: UInt32) -> String?
    func outputChannelCount(on device: UInt32) throws -> UInt32
    func hasProperty(_ property: SystemVolumeAudioProperty, on device: UInt32) -> Bool
    func isSettable(_ property: SystemVolumeAudioProperty, on device: UInt32) throws -> Bool
    func readVolume(channel: UInt32, on device: UInt32) throws -> Float
    func readMute(channel: UInt32, on device: UInt32) throws -> Bool
    func writeVolume(_ value: Float, channel: UInt32, on device: UInt32) throws
    func writeMute(_ value: Bool, channel: UInt32, on device: UInt32) throws
}

extension SystemVolumeAudioBackend {
    func outputDeviceName(on device: UInt32) -> String? { nil }
}

@MainActor
public final class SystemVolumeController {
    public static let shared = SystemVolumeController()
    public static let defaultAdjustmentPercent = 10

    private let backend: any SystemVolumeAudioBackend
    private let scalarTolerance: Float = 0.005

    public convenience init() {
        self.init(backend: CoreAudioSystemVolumeBackend())
    }

    init(backend: any SystemVolumeAudioBackend) {
        self.backend = backend
    }

    /// Writes only the currently selected output device. Every success is based
    /// on a fresh CoreAudio read-back; commands never invoke shell automation.
    public func execute(_ command: SystemVolumeCommand) throws -> SystemVolumeResult {
        switch command {
        case .setPercent(let percent):
            guard (0...100).contains(percent) else { throw SystemVolumeError.invalidPercent }
        case .adjustPercent(let delta):
            guard (-100...100).contains(delta) else { throw SystemVolumeError.invalidPercent }
        case .setMuted, .query:
            break
        }

        let device = try backend.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { throw SystemVolumeError.noOutputDevice }
        let original = try snapshot(on: device)
        let before = original.state
        if command == .query {
            try requireCurrentOutput(device)
            return SystemVolumeResult(before: before, after: before)
        }

        var target = original
        switch command {
        case .setPercent(let percent):
            try target.setVolume(percent: percent)
        case .adjustPercent(let delta):
            guard !original.volumes.isEmpty else { throw SystemVolumeError.unsupportedVolume }
            try target.setVolume(scalar: min(1, max(0, original.maximumVolume + Float(delta) / 100)))
        case .setMuted(let muted):
            guard !target.mutes.isEmpty else { throw SystemVolumeError.unsupportedMute }
            target.mutes = target.mutes.map { ChannelMute(channel: $0.channel, value: muted) }
        case .query:
            break
        }

        // An audible-volume request also clears an exposed hardware mute switch.
        // Do not pretend to unmute a device that has no writable mute property.
        let shouldUnmute: Bool
        switch command {
        case .setPercent(let percent): shouldUnmute = percent > 0
        case .adjustPercent(let delta): shouldUnmute = delta != 0 && target.maximumVolume > 0
        case .setMuted, .query: shouldUnmute = false
        }
        if shouldUnmute, original.state.isMuted == true {
            target.mutes = target.mutes.map { ChannelMute(channel: $0.channel, value: false) }
        }

        let volumeChanges = target.volumes.filter { value in
            original.volumes.first(where: { $0.channel == value.channel })?.value != value.value
        }
        let muteChanges = target.mutes.filter { value in
            original.mutes.first(where: { $0.channel == value.channel })?.value != value.value
        }
        for volume in volumeChanges {
            guard try backend.isSettable(.init(kind: .volume, channel: volume.channel), on: device) else {
                throw SystemVolumeError.unsupportedVolume
            }
        }
        for mute in muteChanges {
            guard try backend.isSettable(.init(kind: .mute, channel: mute.channel), on: device) else {
                throw SystemVolumeError.unsupportedMute
            }
        }
        try requireCurrentOutput(device)

        var writtenVolumes: [ChannelVolume] = []
        var writtenMutes: [ChannelMute] = []
        do {
            for volume in volumeChanges {
                try requireCurrentOutput(device)
                // Include an attempted write: a driver may mutate then report failure.
                writtenVolumes.append(volume)
                try backend.writeVolume(volume.value, channel: volume.channel, on: device)
            }
            for mute in muteChanges {
                try requireCurrentOutput(device)
                writtenMutes.append(mute)
                try backend.writeMute(mute.value, channel: mute.channel, on: device)
            }
            let confirmed = try snapshot(on: device)
            try requireCurrentOutput(device)
            guard confirmed.matches(target, scalarTolerance: scalarTolerance) else {
                throw SystemVolumeError.verificationFailed
            }
            return SystemVolumeResult(before: before, after: confirmed.state)
        } catch {
            // Multi-channel hardware has no atomic setter. Restore attempted
            // properties on the original device, never on a newly routed device.
            for mute in writtenMutes.reversed() {
                if let old = original.mutes.first(where: { $0.channel == mute.channel }) {
                    try? backend.writeMute(old.value, channel: old.channel, on: device)
                }
            }
            for volume in writtenVolumes.reversed() {
                if let old = original.volumes.first(where: { $0.channel == volume.channel }) {
                    try? backend.writeVolume(old.value, channel: old.channel, on: device)
                }
            }
            throw error
        }
    }

    private func requireCurrentOutput(_ device: UInt32) throws {
        guard try backend.defaultOutputDevice() == device else { throw SystemVolumeError.outputDeviceChanged }
    }

    private func snapshot(on device: UInt32) throws -> Snapshot {
        let volumeMaster = SystemVolumeAudioProperty(kind: .volume, channel: kAudioObjectPropertyElementMain)
        let muteMaster = SystemVolumeAudioProperty(kind: .mute, channel: kAudioObjectPropertyElementMain)
        let hasVolumeMaster = backend.hasProperty(volumeMaster, on: device)
        let hasMuteMaster = backend.hasProperty(muteMaster, on: device)
        let channels: [UInt32]
        if hasVolumeMaster && hasMuteMaster {
            channels = []
        } else {
            let count = try backend.outputChannelCount(on: device)
            guard count <= 256 else { throw SystemVolumeError.invalidDeviceValue }
            channels = count > 0 ? Array(1...count) : []
        }
        func supportedChannels(kind: SystemVolumeAudioProperty.Kind, hasMaster: Bool) -> [UInt32] {
            if hasMaster { return [kAudioObjectPropertyElementMain] }
            return channels.allSatisfy { backend.hasProperty(.init(kind: kind, channel: $0), on: device) } ? channels : []
        }
        let volumes = try supportedChannels(kind: .volume, hasMaster: hasVolumeMaster).map { channel in
            let value = try backend.readVolume(channel: channel, on: device)
            guard value.isFinite, (0...1).contains(value) else { throw SystemVolumeError.invalidDeviceValue }
            return ChannelVolume(channel: channel, value: value)
        }
        let mutes = try supportedChannels(kind: .mute, hasMaster: hasMuteMaster).map {
            ChannelMute(channel: $0, value: try backend.readMute(channel: $0, on: device))
        }
        return Snapshot(deviceID: device, deviceName: backend.outputDeviceName(on: device), volumes: volumes, mutes: mutes)
    }

    private struct ChannelVolume { let channel: UInt32; let value: Float }
    private struct ChannelMute { let channel: UInt32; let value: Bool }
    private struct Snapshot {
        let deviceID: UInt32
        let deviceName: String?
        var volumes: [ChannelVolume]
        var mutes: [ChannelMute]

        var maximumVolume: Float { volumes.map(\.value).max() ?? 0 }
        var state: VolumeState {
            VolumeState(
                deviceID: deviceID,
                deviceName: deviceName,
                volumePercent: volumes.isEmpty ? nil : Int((maximumVolume * 100).rounded()),
                isMuted: mutes.isEmpty ? nil : mutes.allSatisfy(\.value)
            )
        }

        mutating func setVolume(percent: Int) throws {
            try setVolume(scalar: Float(percent) / 100)
        }

        mutating func setVolume(scalar desired: Float) throws {
            guard !volumes.isEmpty else { throw SystemVolumeError.unsupportedVolume }
            guard desired.isFinite, (0...1).contains(desired) else { throw SystemVolumeError.invalidPercent }
            let previous = maximumVolume
            // Channel-only devices retain their relative balance. A fully silent
            // output starts all controlled channels at the requested volume.
            volumes = volumes.map {
                ChannelVolume(channel: $0.channel, value: previous > 0 ? min(1, $0.value * desired / previous) : desired)
            }
        }

        func matches(_ expected: Snapshot, scalarTolerance: Float) -> Bool {
            guard deviceID == expected.deviceID, volumes.count == expected.volumes.count,
                  mutes.count == expected.mutes.count else { return false }
            return volumes.allSatisfy { actual in
                guard let target = expected.volumes.first(where: { $0.channel == actual.channel }) else { return false }
                return abs(actual.value - target.value) <= scalarTolerance
            } && mutes.allSatisfy { actual in
                expected.mutes.first(where: { $0.channel == actual.channel })?.value == actual.value
            }
        }
    }
}

@MainActor
private final class CoreAudioSystemVolumeBackend: SystemVolumeAudioBackend {
    func defaultOutputDevice() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw SystemVolumeError.readFailed(status) }
        guard size == MemoryLayout<AudioDeviceID>.size else { throw SystemVolumeError.invalidDeviceValue }
        return device
    }

    func outputDeviceName(on device: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // AudioHardwareBase.h specifies that the caller releases the returned
        // kAudioObjectPropertyName CFObject. Receive its raw retained reference
        // without passing ARC-managed storage to CoreAudio's void* output.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, size == MemoryLayout<Unmanaged<CFString>?>.size,
              let value else { return nil }
        let name = value.takeRetainedValue()
        return String((name as String).prefix(80))
    }

    func outputChannelCount(on device: UInt32) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw SystemVolumeError.readFailed(sizeStatus) }
        guard size >= MemoryLayout<UInt32>.size, size <= 65_536 else {
            throw SystemVolumeError.invalidDeviceValue
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let suppliedSize = size
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage)
        guard status == noErr else { throw SystemVolumeError.readFailed(status) }
        guard size <= suppliedSize else { throw SystemVolumeError.invalidDeviceValue }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(list.pointee.mNumberBuffers)
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? MemoryLayout<UInt32>.size
        guard bufferCount <= 256, headerSize + bufferCount * MemoryLayout<AudioBuffer>.stride <= Int(size) else {
            throw SystemVolumeError.invalidDeviceValue
        }
        var total: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let (next, overflow) = total.addingReportingOverflow(buffer.mNumberChannels)
            guard !overflow, next <= 256 else { throw SystemVolumeError.invalidDeviceValue }
            total = next
        }
        return total
    }

    func hasProperty(_ property: SystemVolumeAudioProperty, on device: UInt32) -> Bool {
        var address = property.address
        return AudioObjectHasProperty(device, &address)
    }

    func isSettable(_ property: SystemVolumeAudioProperty, on device: UInt32) throws -> Bool {
        var address = property.address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        guard status == noErr else { throw SystemVolumeError.readFailed(status) }
        return settable.boolValue
    }

    func readVolume(channel: UInt32, on device: UInt32) throws -> Float {
        var address = SystemVolumeAudioProperty(kind: .volume, channel: channel).address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw SystemVolumeError.readFailed(status) }
        guard size == MemoryLayout<Float32>.size else { throw SystemVolumeError.invalidDeviceValue }
        return value
    }

    func readMute(channel: UInt32, on device: UInt32) throws -> Bool {
        var address = SystemVolumeAudioProperty(kind: .mute, channel: channel).address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw SystemVolumeError.readFailed(status) }
        guard size == MemoryLayout<UInt32>.size, value <= 1 else { throw SystemVolumeError.invalidDeviceValue }
        return value == 1
    }

    func writeVolume(_ value: Float, channel: UInt32, on device: UInt32) throws {
        guard value.isFinite, (0...1).contains(value) else { throw SystemVolumeError.invalidDeviceValue }
        var address = SystemVolumeAudioProperty(kind: .volume, channel: channel).address
        var scalar = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        guard status == noErr else { throw SystemVolumeError.writeFailed(status) }
    }

    func writeMute(_ value: Bool, channel: UInt32, on device: UInt32) throws {
        var address = SystemVolumeAudioProperty(kind: .mute, channel: channel).address
        var flag: UInt32 = value ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag)
        guard status == noErr else { throw SystemVolumeError.writeFailed(status) }
    }
}
