import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var checker: MailChecker

    @AppStorage(MailChecker.notificationsKey) private var notificationsEnabled = true
    @State private var email = ""
    @State private var password = ""
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Notify me about new mail", isOn: $notificationsEnabled)
            Divider().padding(.vertical, 4)

            if !checker.accounts.isEmpty {
                Text("Accounts").font(.headline)
                VStack(spacing: 0) {
                    ForEach(checker.accounts) { account in
                        HStack {
                            Text(account.email)
                            Spacer()
                            Button("Remove") { remove(account.email) }
                        }
                        .padding(.vertical, 6)
                        if account.id != checker.accounts.last?.id {
                            Divider()
                        }
                    }
                }
                Divider().padding(.vertical, 4)
            }

            Text(checker.accounts.isEmpty ? "Add your Gmail account" : "Add another account").font(.headline)

            TextField("Gmail address", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("App password", text: $password)
                .textFieldStyle(.roundedBorder)

            Text("Create an app password at myaccount.google.com/apppasswords. It needs 2-Step Verification turned on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let status {
                    Text(status)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func add() {
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password.replacingOccurrences(of: " ", with: "")
        guard !email.isEmpty, !password.isEmpty else {
            status = "Enter a Gmail address and app password."
            return
        }

        isSaving = true
        status = "Signing in…"
        Task {
            do {
                try await IMAPClient.verify(account: Account(email: email, password: password))
                try Account.add(email: email, password: password)
                self.email = ""
                self.password = ""
                status = "Added \(email)."
                checker.accountsChanged()
            } catch {
                status = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func remove(_ email: String) {
        Account.remove(email: email)
        status = "Removed \(email)."
        checker.accountsChanged()
    }
}

/// A plain AppKit window, because menu bar apps can't reliably bring SwiftUI windows to the front.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(checker: MailChecker) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(checker: checker))
            controller.sizingOptions = [.preferredContentSize] // grow and shrink with the account list
            let window = NSWindow(contentViewController: controller)
            window.title = "MailBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
