import Foundation
import Security

/// Anonymous, account-free user identity.
///
/// A random UUID stored as a *synchronizable* Keychain item: iCloud Keychain
/// carries it to the user's other devices and it survives reinstalling the
/// app, so free/trial/paid usage follows the person, not the install. It is
/// also passed to StoreKit as `appAccountToken`, tying purchases to it.
enum UserIdentity {
    private static let item = KeychainItem(account: "anonymous-user-id", synchronizable: true)

    static let current: UUID = {
        if let stored = item.read(), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        item.write(id.uuidString)
        return id
    }()
}

/// Minimal Keychain wrapper for one string, readable after first unlock (so
/// lease renewal keeps working while the phone is locked during a call).
struct KeychainItem {
    let account: String
    var synchronizable = false
    private let service = "com.deskfox.catchline"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        // Synced items can't be "ThisDeviceOnly".
        q[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
