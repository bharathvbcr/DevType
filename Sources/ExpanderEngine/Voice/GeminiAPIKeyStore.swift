import Foundation
import Security

/// Keychain-backed storage for the Gemini API key
public enum GeminiAPIKeyStore {
    private static let serviceName = "com.devtype.gemini-api-key"
    
    /// Saves the API key to the keychain
    public static func save(_ key: String) throws {
        let keyData = key.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
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
    
    /// Loads the API key from the keychain
    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        return nil
    }
    
    /// Deletes the API key from the keychain
    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "GeminiAPIKeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to delete API key"])
        }
    }
    
    /// Returns true if an API key is stored
    public static var hasKey: Bool {
        return load() != nil
    }
}
