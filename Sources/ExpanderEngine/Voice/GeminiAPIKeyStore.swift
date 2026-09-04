import Foundation
import Security

/// Keychain-backed storage for the Gemini API key
public enum GeminiAPIKeyStore {
    public static let defaultServiceName = "com.devtype.gemini-api-key"
    public static let accountName = "GeminiAPIKey"

    public enum ReadFailure: Equatable, Sendable {
        case keychainStatus(OSStatus)
        case invalidData
    }

    public enum ReadState: Equatable, Sendable {
        case available(String)
        case missing
        case unavailable(ReadFailure)

        public var hasKey: Bool {
            if case .available = self { return true }
            return false
        }
    }

    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    
    /// Saves the API key to the keychain
    public static func save(_ key: String, serviceName: String = defaultServiceName) throws {
        let keyData = key.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            // Update existing
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: keyData
            ]
            status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if status != errSecSuccess {
                throw NSError(domain: "GeminiAPIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to update API key"])
            }
        } else if status == errSecItemNotFound {
            // Add new
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: accountName,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                throw NSError(domain: "GeminiAPIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to save API key"])
            }
        } else {
            throw NSError(domain: "GeminiAPIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to check existing API key"])
        }
    }
    
    /// Reads the API key without collapsing an absent item and an inaccessible Keychain into
    /// the same `nil`. Callers deciding provider readiness must use this typed state so a locked
    /// Keychain cannot silently switch the user's selected speech provider.
    public static func readState(serviceName: String = defaultServiceName) -> ReadState {
        readState(serviceName: serviceName, copyMatching: SecItemCopyMatching)
    }

    static func readState(
        serviceName: String = defaultServiceName,
        copyMatching: CopyMatching
    ) -> ReadState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else {
            return .unavailable(.keychainStatus(status))
        }
        guard let data = dataTypeRef as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return .unavailable(.invalidData)
        }
        return .available(key)
    }

    /// Compatibility accessor for the network adapter. UI/readiness code uses `readState()`.
    public static func load(serviceName: String = defaultServiceName) -> String? {
        guard case .available(let key) = readState(serviceName: serviceName) else { return nil }
        return key
    }
    
    /// Deletes the API key from the keychain
    public static func delete(serviceName: String = defaultServiceName) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "GeminiAPIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to delete API key"])
        }
    }
    
    /// Returns true if an API key is stored
    public static var hasKey: Bool {
        readState().hasKey
    }
}
