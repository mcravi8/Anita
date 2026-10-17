import Foundation
import Darwin

struct BuddyProtocolLines {
    private var pending = Data()
    mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 10) {
            pending.append(data[start..<newline])
            lines.append(pending)
            pending = Data()
            start = data.index(after: newline)
        }
        pending.append(data[start...])
        return lines
    }
}

enum BuddyTurnScope {
    static func matches(_ parameters: [String: Any], turnID: String) -> Bool {
        let eventID = parameters["turnId"] as? String ?? (parameters["turn"] as? [String: Any])?["id"] as? String
        return eventID == turnID
    }
}

enum BuddyPipeReader {
    static func read(_ handle: FileHandle, deliver: (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            // Foundation read(upToCount:) can wait for the entire requested count on pipes.
            // One POSIX read returns the available bytes immediately, preserving RPC latency.
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 { if errno == EINTR { continue }; return }
            deliver(Data(bytes.prefix(count)))
        }
    }
}
