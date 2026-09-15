import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error, LocalizedError {
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .interactionNotAllowed: "Unlock the login Keychain to load the OpenAI API key."
        case .unexpectedStatus(let status): "Keychain operation failed with status \(status)."
        }
    }
}

public struct KeychainAPIKeyStore: APIKeyStoring, Sendable {
    private let service: String
    private let account: String

    public init(service: String = "app.videocontext.mac", account: String = "openai-api-key") {
        self.service = service
        self.account = account
    }

    @concurrent
    public func load(mode: APIKeyAccessMode) async throws -> String? {
        let context = LAContext()
        context.localizedReason = account == "lm-studio-token"
            ? "Video Context needs the saved LM Studio token for local processing."
            : "Video Context needs the saved OpenAI API key to resume video processing."
        context.interactionNotAllowed = mode == .nonInteractive
        let data = try Self.read(
            service: service,
            account: account,
            context: context,
            failAuthenticationUI: mode == .nonInteractive
        )
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    @concurrent
    public func save(_ key: String) async throws {
        try Self.upsert(Data(key.utf8), service: service, account: account)
    }

    @concurrent
    public func remove() async throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func read(
        service: String,
        account: String,
        context: LAContext,
        failAuthenticationUI: Bool
    ) throws -> Data? {
        try read(
            service: service,
            account: account,
            context: context,
            failAuthenticationUI: failAuthenticationUI,
            copyMatching: SecItemCopyMatching
        )
    }

    static func read(
        service: String,
        account: String,
        context: LAContext,
        failAuthenticationUI: Bool,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        if failAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        var status = copyMatching(query as CFDictionary, &result)

        // Some locally signed builds reject kSecUseAuthenticationContext with
        // errSecMissingEntitlement even for a standard login-Keychain item. The
        // compatibility query keeps the noninteractive UI policy but lets the
        // normal login Keychain perform the lookup without an LAContext.
        if status == errSecMissingEntitlement {
            query.removeValue(forKey: kSecUseAuthenticationContext as String)
            result = nil
            status = copyMatching(query as CFDictionary, &result)
        }

        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw KeychainError.interactionNotAllowed }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    private static func upsert(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let query = baseQuery(service: service, account: account)
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
