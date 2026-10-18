import Foundation

/// Notifications that arrive over IPC (`notify`). Kept apart from agent tasks on
/// purpose (decision D11): own rows, own unread count, own deduplication.
///
/// Thread-safe: IPC connections write from their own queue while the overlay
/// reads from the main thread.
public final class ExternalInbox: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let client: String
        public let title: String
        public let receivedAt: Date
        public fileprivate(set) var isRead: Bool
    }

    /// How many rows the overlay lists.
    public let limit: Int
    private let capacity: Int
    private let dedupCapacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// FIFO of `client` + event id pairs; a repeat is a retry, not a new row.
    private var seen: [String] = []
    private var seenSet: Set<String> = []

    public init(limit: Int = 10, capacity: Int = 200, dedupCapacity: Int = 512) {
        self.limit = max(1, limit)
        self.capacity = max(self.limit, capacity)
        self.dedupCapacity = max(1, dedupCapacity)
    }

    /// Adds one notification unless that client already sent this event id
    /// within the deduplication window. Returns nil for a duplicate.
    @discardableResult
    public func add(client: String, title: String, eventID: String, at date: Date) -> Entry? {
        let key = Self.key(client: client, eventID: eventID)
        lock.lock()
        defer { lock.unlock() }
        guard !seenSet.contains(key) else { return nil }
        remember(key)
        let entry = Entry(id: key, client: client, title: title, receivedAt: date, isRead: false)
        entries.insert(entry, at: 0)
        trim()
        return entry
    }

    public var allEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public var unreadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.lazy.filter { !$0.isRead }.count
    }

    /// What the overlay renders: the newest `limit` rows.
    public var visibleEntries: [Entry] { Array(allEntries.prefix(limit)) }

    public func markRead(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isRead = true
    }

    private func remember(_ key: String) {
        seen.append(key)
        seenSet.insert(key)
        if seen.count > dedupCapacity {
            seenSet.remove(seen.removeFirst())
        }
    }

    /// Drops the oldest read rows; unread ones stay until they are read.
    private func trim() {
        var excess = entries.count - capacity
        guard excess > 0 else { return }
        var index = entries.count - 1
        while excess > 0 && index >= 0 {
            if entries[index].isRead {
                entries.remove(at: index)
                excess -= 1
            }
            index -= 1
        }
    }

    private static func key(client: String, eventID: String) -> String {
        "\(client)\u{1F}\(eventID)"
    }
}
