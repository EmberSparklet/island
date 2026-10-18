import Foundation
import IslandCore

/// `island notify [--title <text>] [--kind notice|task.finished] [--client <name>]`
///
/// A thin CLI over the same socket and protocol a plugin or another app would
/// use, so any language can integrate with one line of shell.
enum IPCCLI {
    private struct Notification {
        let title: String
        let kind: String
        let client: String
    }

    static func runNotify(_ arguments: [String], environment: [String: String]) -> Int32 {
        guard let notification = parse(arguments) else { return usage() }
        let settings = IPCSettings.resolve(environment: environment)
        guard let socketURL = settings.socketURL else {
            writeError("island ipc is switched off (ISLAND_IPC=off)")
            return 1
        }
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            writeError("island is not running: no socket at \(socketURL.path)")
            return 1
        }
        let fd = connectToSocket(socketURL.path)
        guard fd >= 0 else {
            writeError("cannot connect to island at \(socketURL.path)")
            return 1
        }
        defer { close(fd) }

        let hello = request(
            fd: fd, id: "hello", method: "hello",
            params: [
                "client": notification.client,
                "protocol": IPCProtocol.version,
                "pid": Int(getpid()),
            ])
        guard hello?["ok"] as? Bool == true else {
            writeError(errorText(hello) ?? "island did not answer hello")
            return 1
        }

        let reply = request(
            fd: fd, id: UUID().uuidString, method: "notify",
            params: [
                "kind": notification.kind,
                "title": notification.title,
                "client_event_id": UUID().uuidString,
            ])
        guard let reply, reply["ok"] as? Bool == true else {
            writeError(errorText(reply) ?? "island did not accept the notification")
            return 1
        }
        let duplicate = (reply["result"] as? [String: Any])?["duplicate"] as? Bool == true
        print("notified island: \(notification.title)\(duplicate ? " (duplicate)" : "")")
        return 0
    }

    private static func parse(_ arguments: [String]) -> Notification? {
        var title: String?
        var kind = "notice"
        var client = "island-cli"
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--title", "--kind", "--client":
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                switch argument {
                case "--title": title = value
                case "--kind": kind = value
                default: client = value
                }
                index += 2
            default:
                guard title == nil, !argument.hasPrefix("--") else { return nil }
                title = argument
                index += 1
            }
        }
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            IPCProtocol.notifyKinds.contains(kind)
        else { return nil }
        return Notification(title: title, kind: kind, client: client)
    }

    private static func usage() -> Int32 {
        writeError(
            "usage: island notify [--title <text>] [--kind notice|task.finished] [--client <name>]"
        )
        return 2
    }

    private static func connectToSocket(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = UnixSocket.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        // Never let a wedged island hang a script.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func request(
        fd: Int32, id: String, method: String, params: [String: Any]
    ) -> [String: Any]? {
        let frame: [String: Any] = [
            "v": IPCProtocol.version, "id": id, "method": method, "params": params,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]),
            UnixSocket.writeAll(fd, body + Data([0x0A])),
            let line = UnixSocket.readLine(fd)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func errorText(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["detail"] as? String
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("island notify: \(message)\n".utf8))
    }
}
