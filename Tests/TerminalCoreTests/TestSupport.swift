import os
@testable import TerminalCore

/// 送信されたフレームを記録するだけの sink。`connected` を false にすると切断中として扱う。
final class RecordingSink: TerminalFrameSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (frames: [TerminalOutgoingFrame](), connected: true))

    var frames: [TerminalOutgoingFrame] { state.withLock { $0.frames } }

    var connected: Bool {
        get { state.withLock { $0.connected } }
        set { state.withLock { $0.connected = newValue } }
    }

    var inputFrames: [[UInt8]] {
        frames.compactMap { frame in
            if case .input(_, let bytes) = frame { return bytes }
            return nil
        }
    }

    func removeAll() {
        state.withLock { $0.frames.removeAll() }
    }

    @discardableResult
    func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
        state.withLock { state in
            guard state.connected else { return false }
            state.frames.append(frame)
            return true
        }
    }
}

func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }
