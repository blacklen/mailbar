import Foundation
import Security

/// A Gmail account MailBar checks. Addresses live in UserDefaults, app passwords in the Keychain.
struct Account: Sendable, Identifiable {
    let email: String
    let password: String

    var id: String { email }

    private static let emailsKey = "emails"
    private static let legacyEmailKey = "email" // single-account versions stored one address here

    static var emails: [String] {
        let defaults = UserDefaults.standard
        if let emails = defaults.stringArray(forKey: emailsKey) { return emails }
        guard let legacy = defaults.string(forKey: legacyEmailKey) else { return [] }
        defaults.set([legacy], forKey: emailsKey)
        defaults.removeObject(forKey: legacyEmailKey)
        return [legacy]
    }

    static func loadAll() -> [Account] {
        emails.compactMap { email in
            Keychain.password(for: email).map { Account(email: email, password: $0) }
        }
    }

    /// Adds the account, or replaces the password if the address is already added.
    static func add(email: String, password: String) throws {
        try Keychain.save(password: password, for: email)
        var emails = emails
        if !emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            emails.append(email)
            UserDefaults.standard.set(emails, forKey: emailsKey)
        }
    }

    static func remove(email: String) {
        Keychain.deletePassword(for: email)
        UserDefaults.standard.set(emails.filter { $0 != email }, forKey: emailsKey)
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Couldn't save the password to the Keychain (error \(status))."
        }
    }
}

enum Keychain {
    private static let service = "MailBar"

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(password: String, for account: String) throws {
        deletePassword(for: account)
        var item = query(for: account)
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func password(for account: String) -> String? {
        var search = query(for: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
    }
}
