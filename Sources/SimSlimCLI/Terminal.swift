import Darwin
import Foundation

func isTerminal(_ descriptor: Int32) -> Bool {
    isatty(descriptor) == 1
}

struct RawTerminal {
    private let descriptor: Int32
    private let original: termios

    init(descriptor: Int32 = STDIN_FILENO) throws {
        self.descriptor = descriptor
        var state = termios()
        guard tcgetattr(descriptor, &state) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        original = state

        var raw = state
        cfmakeraw(&raw)
        guard tcsetattr(descriptor, TCSAFLUSH, &raw) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func restore() {
        var state = original
        tcsetattr(descriptor, TCSAFLUSH, &state)
    }
}
