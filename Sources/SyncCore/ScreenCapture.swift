import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Streams small, downscaled frames of one display via ScreenCaptureKit.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: `stream` is only touched from start()/stop(), which callers serialize (the main actor).

    /// Output width in pixels; height follows the display's aspect ratio.
    public static let frameWidth = 160

    private let onFrame: @Sendable (Frame) -> Void
    private let onStop: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "blask.screen-capture", qos: .userInteractive)
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

    /// Captures `displayID` at up to 30 fps, leaving out this app's own windows.
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
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
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        onFrame(Frame(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(bytes: base, count: bytesPerRow * height)
        ))
    }

    /// Idle frames (screen unchanged) carry no new image.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
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
