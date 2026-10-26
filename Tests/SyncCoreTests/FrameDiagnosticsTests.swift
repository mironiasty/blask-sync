import Foundation
import ScreenCaptureKit
import Testing

@testable import SyncCore

struct FrameDiagnosticsTests {
    private func frame(gray: UInt8) -> Frame {
        Frame(width: 4, height: 4, bytesPerRow: 16, pixels: Data(repeating: gray, count: 64))
    }

    @Test func summarizesStatusesAndDarkFramesPerWindow() {
        var diagnostics = FrameDiagnostics()
        #expect(diagnostics.record(status: .complete, frame: frame(gray: 0), now: 0) == nil)
        #expect(diagnostics.record(status: .idle, frame: nil, now: 1) == nil)
        #expect(diagnostics.record(status: .complete, frame: frame(gray: 200), now: 2) == nil)

        let summary = diagnostics.record(status: .complete, frame: frame(gray: 1), now: 5)
        #expect(summary == "4 buffers in 5.0 s (complete 3, idle 1), 2 complete frames nearly black")
        // The next window starts empty.
        #expect(diagnostics.record(status: .idle, frame: nil, now: 6) == nil)
    }
}
