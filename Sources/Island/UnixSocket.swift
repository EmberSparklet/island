import Foundation

/// POSIX plumbing shared by the IPC server and the `island notify` client.
/// Kept in one place so the socket address layout is written down once.
enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let destination = raw.bindMemory(to: CChar.self)
            for (index, byte) in path.utf8CString.enumerated() where index < destination.count {
                destination[index] = byte
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads one newline-terminated frame; nil on EOF, error, or an oversized
    /// line.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<newline])
            }
            if buffer.count > limit { return nil }
        }
    }
}
