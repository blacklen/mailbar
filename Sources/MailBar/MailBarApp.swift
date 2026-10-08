import AppKit
import SwiftUI
import UserNotifications

@main
struct MailBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var checker = MailChecker.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(checker: checker)
        } label: {
            MenuBarLabel(checker: checker)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if Account.emails.isEmpty {
            SettingsWindow.show(checker: .shared)
        }
    }

    // Show banners even though MailBar counts as the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens the email (or the inbox) in Gmail.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}


/// "99+" above 99, and never a locale separator like "32.856".
private func countText(_ count: Int) -> String {
    count > 99 ? "99+" : String(count)
}

struct MenuBarLabel: View {
    @ObservedObject var checker: MailChecker

    var body: some View {
        // Icon only: envelope.badge adds a dot when there's unread mail. Counts live in the dropdown.
        let count = checker.unreadCount ?? 0
        Image(systemName: checker.hasError ? "exclamationmark.triangle" : count > 0 ? "envelope.badge" : "envelope")
    }
}

struct MenuContent: View {
    @ObservedObject var checker: MailChecker

    /// Addresses of the open sections, one per line. nil until you first open or close one.
    @AppStorage("expandedAccounts") private var expandedRaw: String?
    @State private var listHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if checker.needsSetup {
                Button("Set up your Gmail account…") { SettingsWindow.show(checker: checker) }
                    .padding(14)
            } else {
                // Size the scroll area to the list, up to maxListHeight.
                ScrollView {
                    accountList.onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), maxListHeight))
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var expanded: Set<String> {
        guard let expandedRaw else { return Set(checker.accounts.prefix(1).map(\.email)) }
        return Set(expandedRaw.split(separator: "\n").map(String.init))
    }

    private func toggle(_ email: String) {
        var expanded = expanded
        if expanded.contains(email) {
            expanded.remove(email)
        } else {
            expanded.insert(email)
        }
        expandedRaw = expanded.sorted().joined(separator: "\n")
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(checker.accounts) { account in
                AccountSection(
                    account: account,
                    isExpanded: expanded.contains(account.email),
                    toggle: { toggle(account.email) },
                    markRead: { email in Task { await checker.markAsRead(email, accountEmail: account.email) } },
                    markAllRead: { confirmMarkAllRead(account) }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func confirmMarkAllRead(_ account: AccountStatus) {
        let alert = NSAlert()
        alert.messageText = "Mark all as read?"
        let count = account.unreadCount.map { "all \($0) unread emails" } ?? "all unread emails"
        alert.informativeText = "This marks \(count) in the Primary tab of \(account.email) as read. You can't undo this from MailBar."
        alert.addButton(withTitle: "Mark all as read")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await checker.markAllAsRead(accountEmail: account.email) }
        }
    }

    private var header: some View {
        HStack {
            Text("Primary inbox").font(.system(size: 13, weight: .semibold))
            Spacer()
            if checker.isChecking {
                ProgressView().controlSize(.small)
            } else if let lastChecked = checker.lastChecked {
                Text("Updated \(lastChecked.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Check now") { Task { await checker.check() } }
                .disabled(checker.isChecking || checker.needsSetup)
            Spacer()
            Button("Settings…") { SettingsWindow.show(checker: checker) }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct AccountSection: View {
    let account: AccountStatus
    let isExpanded: Bool
    let toggle: () -> Void
    let markRead: (Email) -> Void
    let markAllRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoverRow(action: toggle) { _ in
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(account.email)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if account.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if let count = account.unreadCount {
                        CountBadge(count: count)
                    }
                }
                .padding(.vertical, 7)
            }

            if isExpanded {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = account.error {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
                .padding(.trailing, 14)
                .padding(.vertical, 4)
        }
        if let actionError = account.actionError {
            Text(actionError)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
                .padding(.trailing, 14)
                .padding(.vertical, 4)
        }

        if account.emails.isEmpty {
            if account.error == nil || account.unreadCount != nil {
                Text(account.unreadCount == nil ? "Checking…" : "No unread email")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
            }
        } else {
            ForEach(account.emails) { email in
                EmailRow(email: email, markRead: { markRead(email) })
            }
        }

        HStack(spacing: 14) {
            Button("Open Gmail") { NSWorkspace.shared.open(Gmail.inboxURL(for: account.email)) }
            if (account.unreadCount ?? 0) > 0 {
                Button("Mark all as read", action: markAllRead)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.leading, 34)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

struct EmailRow: View {
    let email: Email
    let markRead: () -> Void

    var body: some View {
        HoverRow(action: { NSWorkspace.shared.open(email.url) }) { isHovered in
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: email.from)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(email.from)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isHovered {
                            Button(action: markRead) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.borderless)
                            .help("Mark as read")
                        } else if let date = email.date {
                            Text(Self.shortDate(date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(email.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 20)
            .padding(.vertical, 6)
        }
    }

    private static func shortDate(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A full-width clickable row with a rounded highlight on hover, like a native menu item.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (_ isHovered: Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
            // A tap gesture instead of a Button, so a row can contain its own buttons.
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 6)
            .onHover { isHovered = $0 }
    }
}

struct Avatar: View {
    let name: String

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red]

    var body: some View {
        // Sum of character codes, so the same sender always gets the same color.
        let color = Self.colors[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colors.count]
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color.gradient))
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(countText(count))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(count > 0 ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(count > 0 ? Color.accentColor : Color.secondary.opacity(0.15)))
    }
}
