import CoreAudio
import Foundation
import os

/// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2+), as mono samples.
///
/// Audio only: unlike ScreenCaptureKit's audio, no display is captured, so it doesn't make macOS hide
/// DRM-protected video. Needs the System Audio Recording permission; without it, macOS delivers silence.
public final class SystemAudioTap: @unchecked Sendable {
    // @unchecked: the Core Audio object IDs are only touched from start()/stop(), which callers
    // serialize (the main actor); `mono` and `levelStats` only on `queue`.

    /// Receives mono samples and their sample rate, on the tap's queue.
    public typealias SampleHandler = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void

    private let onSamples: SampleHandler
    private let queue = DispatchQueue(label: "blask.audio-tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var mono: [Float] = []
    private var levelStats = LevelStats()
    private static let logger = Logger(subsystem: "local.blasksync", category: "audio")

    public init(onSamples: @escaping SampleHandler) {
        self.onSamples = onSamples
    }

    deinit {
        stop()
    }

    public var isRunning: Bool { procID != nil }

    public func start() throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Blask Sync"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the audio tap")
        tapID = tap

        do {
            let format = try Self.property(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw TapError(step: "read the audio format", status: kAudioHardwareUnsupportedOperationError)
            }
            let outputUID = try Self.defaultOutputDeviceUID()

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Blask Sync Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the capture device")
            aggregateID = device

            let channels = Int(format.mChannelsPerFrame)
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let sampleRate = format.mSampleRate
            var proc: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                    self?.handle(input, channels: channels, interleaved: interleaved, sampleRate: sampleRate)
                }, "attach to the capture device")
            procID = proc
            try check(AudioDeviceStart(device, proc), "start capturing")
            Self.logger.notice("audio tap started: \(sampleRate, privacy: .public) Hz, \(channels) channels")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: Buffers

    /// Runs on `queue`.
    private func handle(_ input: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard channels > 0, let first = buffers.first, let firstData = first.mData else { return }

        let frames =
            interleaved
            ? Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            : Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }

        let scale = 1 / Float(channels)
        if interleaved {
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono[frame] = sum * scale
            }
        } else {
            for frame in 0..<frames { mono[frame] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { mono[frame] += samples[frame] * scale }
            }
        }

        if let summary = levelStats.record(mono) {
            Self.logger.notice("\(summary, privacy: .public)")
        }
        mono.withUnsafeBufferPointer { onSamples($0, sampleRate) }
    }

    // MARK: Core Audio helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type)
        throws -> T
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        guard status == noErr else { throw TapError(step: "read audio property", status: status) }
        return value.pointee
    }

    private static func defaultOutputDeviceUID() throws -> String {
        let device = try property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
            as: AudioObjectID.self)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError(step: "find the output device", status: status) }
        return uid.takeRetainedValue() as String
    }

    public struct TapError: LocalizedError {
        public let step: String
        public let status: OSStatus

        public var errorDescription: String? {
            "Couldn't \(step) (Core Audio error \(status))."
        }
    }
}

/// Peak level of the captured audio per 5 s. A permanent −∞ dB while music plays means the
/// System Audio Recording permission is missing (macOS then delivers silence).
struct LevelStats {
    private var windowStart: TimeInterval?
    private var buffers = 0
    private var peak: Float = 0

    mutating func record(_ samples: [Float], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        buffers += 1
        for sample in samples { peak = max(peak, abs(sample)) }
        guard let start = windowStart else {
            windowStart = now
            return nil
        }
        guard now - start >= 5 else { return nil }
        let decibels = peak > 0 ? String(format: "%.0f dB", 20 * log10(peak)) : "silent"
        let summary = String(format: "audio: %d buffers in %.1f s, peak %@", buffers, now - start, decibels)
        windowStart = now
        buffers = 0
        peak = 0
        return summary
    }
}
