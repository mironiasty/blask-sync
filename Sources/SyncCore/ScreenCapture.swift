import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Streams small, downscaled frames of one display via ScreenCaptureKit.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: `stream` is only touched from start()/stop(), which callers serialize (the main actor).

    /// Output width in pixels; height follows the display's aspect ratio.
    public static let frameWidth = 160

    private let onFrame: @Sendable (Frame) -> Void
    private let onStop: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "blask.screen-capture", qos: .userInteractive)
    private let diagnostics = OSAllocatedUnfairLock(initialState: FrameDiagnostics())
    private static let logger = Logger(subsystem: "local.blasksync", category: "capture")
    private var stream: SCStream?

    /// - Parameters:
    ///   - onFrame: Called on a capture queue for every new frame (only when the screen changes).
    ///   - onStop: Called if the system stops the stream, e.g. when permission is revoked.
    public init(onFrame: @escaping @Sendable (Frame) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user has to use System Settings.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures `displayID` at up to 60 fps, leaving out this app's own windows.
    public func start(displayID: CGDirectDisplayID) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = Self.frameWidth
        configuration.height = max(1, Int((Double(Self.frameWidth) * Double(display.height) / Double(display.width)).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let status = Self.status(of: sampleBuffer)
        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else {
            record(status: status, frame: nil)
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let frame = Frame(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(bytes: base, count: bytesPerRow * height)
        )
        record(status: status, frame: frame)
        onFrame(frame)
    }

    /// Only `.complete` frames carry a new image; `.idle` means the screen didn't change.
    private static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: rawStatus)
    }

    private func record(status: SCFrameStatus?, frame: Frame?) {
        let summary = diagnostics.withLock { $0.record(status: status, frame: frame) }
        if let summary {
            Self.logger.notice("\(summary, privacy: .public)")
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    public enum CaptureError: LocalizedError {
        case noDisplay

        public var errorDescription: String? {
            switch self {
            case .noDisplay: "The selected display isn't available."
            }
        }
    }
}

/// Counts delivered sample buffers by status, and how many complete frames are nearly black, per 5 s.
/// Explains low frame rates: few callbacks (nothing delivered), mostly idle (screen seen as unchanged),
/// or mostly dark (e.g. DRM-protected video, which screen capture sees as black).
struct FrameDiagnostics {
    private var windowStart: TimeInterval?
    private var counts: [String: Int] = [:]
    private var darkFrames = 0

    mutating func record(status: SCFrameStatus?, frame: Frame?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        counts[Self.name(of: status), default: 0] += 1
        if let frame, Self.isDark(frame) { darkFrames += 1 }

        guard let start = windowStart else {
            windowStart = now
            return nil
        }
        guard now - start >= 5 else { return nil }
        let total = counts.values.reduce(0, +)
        let breakdown = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let summary = String(format: "%d buffers in %.1f s (%@), %d complete frames nearly black", total, now - start, breakdown, darkFrames)
        windowStart = now
        counts = [:]
        darkFrames = 0
        return summary
    }

    private static func name(of status: SCFrameStatus?) -> String {
        switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        case nil: "unknown"
        @unknown default: "other"
        }
    }

    /// Samples every 4th pixel; "dark" means average brightness below 2%.
    private static func isDark(_ frame: Frame) -> Bool {
        frame.pixels.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var sum = 0, samples = 0
            for y in stride(from: 0, to: frame.height, by: 2) {
                for x in stride(from: 0, to: frame.width, by: 2) {
                    let offset = y * frame.bytesPerRow + x * 4
                    sum += Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                    samples += 3
                }
            }
            return samples > 0 && Double(sum) / Double(samples * 255) < 0.02
        }
    }
}
