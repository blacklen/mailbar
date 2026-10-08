import Foundation
import UserNotifications

/// What the menu shows for one account.
struct AccountStatus: Identifiable {
    let email: String
    var unreadCount: Int?
    var emails: [Email] = []
    var error: String?
    /// A failed mark-as-read. Kept separate so the next check doesn't clear it.
    var actionError: String?

    var id: String { email }
}

/// Checks every account's inbox each minute and posts a notification for new unread mail.
@MainActor
final class MailChecker: ObservableObject {
    static let shared = MailChecker()

    @Published private(set) var accounts: [AccountStatus] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false

    var needsSetup: Bool { accounts.isEmpty }
    var hasError: Bool { accounts.contains { $0.error != nil } }

    /// Total across accounts; nil until at least one account has been checked.
    var unreadCount: Int? {
        let counts = accounts.compactMap(\.unreadCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    private let interval: TimeInterval = 60
    private let listLimit = 10

    /// Unread UIDs per account from the last check. Missing until an account's first check,
    /// so mail that was already there doesn't trigger notifications.
    private var knownUnread: [String: Set<UInt32>] = [:]
    private var recheckRequested = false
    private var timer: Timer?

    private init() {
        accounts = Account.emails.map { AccountStatus(email: $0) }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func accountsChanged() {
        let emails = Account.emails
        accounts = emails.map { email in accounts.first { $0.email == email } ?? AccountStatus(email: email) }
        knownUnread = knownUnread.filter { emails.contains($0.key) }
        Task { await check() }
    }

    func check() async {
        guard !isChecking else {
            recheckRequested = true
            return
        }
        let accountsToCheck = Account.loadAll()
        guard !accountsToCheck.isEmpty else {
            accounts = []
            return
        }

        isChecking = true
        let limit = listLimit
        // Check all accounts at the same time, off the main thread.
        let tasks = accountsToCheck.map { account in
            Task.detached { try await IMAPClient.fetchUnread(account: account, limit: limit) }
        }
        var results: [String: Result<UnreadResult, Error>] = [:]
        for (account, task) in zip(accountsToCheck, tasks) {
            results[account.email] = await task.result
        }

        accounts = accountsToCheck.map { account in
            var status = accounts.first { $0.email == account.email } ?? AccountStatus(email: account.email)
            switch results[account.email] {
            case .success(let result):
                if let known = knownUnread[account.email] {
                    notify(newUIDs: result.unreadUIDs.subtracting(known), emails: result.emails, account: account)
                }
                knownUnread[account.email] = result.unreadUIDs
                status.unreadCount = result.unreadUIDs.count
                status.emails = result.emails
                status.error = nil
            case .failure(let error):
                status.error = error.localizedDescription
            case nil:
                break
            }
            return status
        }
        lastChecked = Date()
        isChecking = false

        if recheckRequested {
            recheckRequested = false
            await check()
        }
    }

    func markAsRead(_ email: Email, accountEmail: String) async {
        guard let account = Account.loadAll().first(where: { $0.email == accountEmail }) else { return }
        updateStatus(accountEmail) { status in
            status.actionError = nil
            status.emails.removeAll { $0.uid == email.uid }
            status.unreadCount = status.unreadCount.map { max($0 - 1, 0) }
        }
        knownUnread[accountEmail]?.remove(email.uid)

        do {
            try await IMAPClient.markAsRead(account: account, uids: [email.uid])
        } catch {
            updateStatus(accountEmail) { $0.actionError = "Couldn't mark as read: \(error.localizedDescription)" }
        }
        await check() // refill the list from Gmail
    }

    func markAllAsRead(accountEmail: String) async {
        guard let account = Account.loadAll().first(where: { $0.email == accountEmail }) else { return }
        updateStatus(accountEmail) { status in
            status.actionError = nil
            status.emails = []
            status.unreadCount = 0
        }
        knownUnread[accountEmail] = []

        do {
            _ = try await IMAPClient.markAllAsRead(account: account)
        } catch {
            updateStatus(accountEmail) { $0.actionError = "Couldn't mark all as read: \(error.localizedDescription)" }
        }
        await check()
    }

    private func updateStatus(_ email: String, _ change: (inout AccountStatus) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        change(&accounts[index])
    }

    private func notify(newUIDs: Set<UInt32>, emails: [Email], account: Account) {
        guard !newUIDs.isEmpty else { return }
        let newEmails = emails.filter { newUIDs.contains($0.uid) }

        let content = UNMutableNotificationContent()
        content.subtitle = account.email
        if newUIDs.count == 1, let email = newEmails.first {
            content.title = email.from
            content.body = email.subject
            content.userInfo = ["url": email.url.absoluteString]
        } else {
            content.title = "\(newUIDs.count) new emails"
            content.body = newEmails.prefix(3).map { "\($0.from): \($0.subject)" }.joined(separator: "\n")
            content.userInfo = ["url": Gmail.inboxURL(for: account.email).absoluteString]
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
