import FaceUnlockCore
import Foundation
import OpenDirectory
import Security

/// A password held as UTF-16 code units in memory we own, so it can be
/// overwritten when no longer needed. This narrows, but cannot eliminate,
/// copies: the Security framework, CGEvent and the password field itself
/// keep their own short-lived copies that we can't reach.
final class SecretUTF16: @unchecked Sendable {
    private var buffer: UnsafeMutableBufferPointer<UInt16>
    private(set) var count: Int

    /// Decodes UTF-8 bytes straight into the owned buffer (no String).
    init?(utf8 bytes: UnsafeBufferPointer<UInt8>) {
        buffer = .allocate(capacity: max(bytes.count, 1))
        buffer.initialize(repeating: 0)
        count = 0
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var ok = true
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                UTF16.encode(scalar) { unit in
                    buffer[count] = unit
                    count += 1
                }
            case .emptyInput:
                break loop
            case .error:
                ok = false
                break loop
            }
        }
        if !ok || count == 0 {
            wipe()
            return nil
        }
    }

    /// Unicode scalars as 1–2 UTF-16 units each (surrogate pairs kept together).
    func forEachScalar(_ body: (UnsafeBufferPointer<UInt16>) throws -> Void) rethrows {
        var i = 0
        while i < count {
            let isHighSurrogate = (0xD800...0xDBFF).contains(buffer[i])
            let length = isHighSurrogate && i + 1 < count ? 2 : 1
            try body(UnsafeBufferPointer(rebasing: buffer[i..<(i + length)]))
            i += length
        }
    }

    func wipe() {
        guard buffer.count > 0 else { return }
        buffer.update(repeating: 0)
        buffer.deallocate()
        buffer = UnsafeMutableBufferPointer(start: nil, count: 0)
        count = 0
    }

    deinit { wipe() }
}

/// Hands a result from the Keychain worker thread back to the waiter; the
/// semaphore orders the write before the read.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Keychain storage: the Mac login password plus an integrity record.
/// Nothing here logs or persists the password anywhere else.
enum PasswordVault {
    static let service = "uk.co.sid.faceunlock"
    static let passwordAccount = "macos-login-password"
    static let integrityAccount = "integrity"
    static let readTimeout: TimeInterval = 3

    enum VaultError: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case encoding
        case timedOut

        var description: String {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            case .encoding: return "Stored data could not be decoded."
            case .timedOut: return "Keychain read timed out."
            }
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func store(_ data: Data, account: String, label: String) throws {
        // Replace rather than update, so the item's access attributes are fresh.
        SecItemDelete(baseQuery(account) as CFDictionary)
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = label
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    /// Runs a prompt-free SecItemCopyMatching for the item's data on a
    /// separate thread and gives up after `readTimeout`, so a stuck Keychain
    /// call can't wedge the caller. `transform` must consume the CFData.
    private static func readData<T: Sendable>(account: String, _ transform: @escaping @Sendable (CFData) throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var query = baseQuery(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            // kSecUseAuthenticationUI = kSecUseAuthenticationUIFail. Spelled as
            // the underlying string values because the constants are
            // deprecated, but they are what makes the file-based login
            // keychain fail instead of showing an access prompt (nobody can
            // answer a prompt at the lock screen).
            query["u_AuthUI"] = "u_AuthUIF"
            var ref: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &ref)
            let result: Result<T, Error>
            if status == errSecSuccess, let ref, CFGetTypeID(ref) == CFDataGetTypeID() {
                result = Result { try transform(ref as! CFData) }
            } else {
                result = .failure(VaultError.keychain(status))
            }
            box.result = result
            done.signal()
        }
        guard done.wait(timeout: .now() + readTimeout) == .success, let result = box.result else {
            throw VaultError.timedOut
        }
        return try result.get()
    }

    // MARK: Password

    static func savePassword(_ password: String) throws {
        guard var data = password.data(using: .utf8) else { throw VaultError.encoding }
        defer { data.resetBytes(in: 0..<data.count) }
        try store(data, account: passwordAccount, label: "FaceUnlock (Mac login password)")
    }

    /// Whether the password item exists. Reads attributes only, never the
    /// secret, so it can't trigger a Keychain access prompt.
    static func passwordExists() -> Bool {
        var query = baseQuery(passwordAccount)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the password into wipeable memory. The CFData returned by the
    /// Keychain is overwritten as soon as it has been decoded (best effort:
    /// it is our only reference to that buffer).
    static func readPassword() throws -> SecretUTF16 {
        try readData(account: passwordAccount) { cfData in
            let length = CFDataGetLength(cfData)
            guard length > 0, let bytes = CFDataGetBytePtr(cfData) else { throw VaultError.encoding }
            defer { UnsafeMutablePointer(mutating: bytes).update(repeating: 0, count: length) }
            guard let secret = SecretUTF16(utf8: UnsafeBufferPointer(start: bytes, count: length)) else {
                throw VaultError.encoding
            }
            return secret
        }
    }

    // MARK: Integrity record

    static func saveIntegrity(_ record: IntegrityRecord) throws {
        let data = try JSONEncoder().encode(record)
        try store(data, account: integrityAccount, label: "FaceUnlock (template integrity)")
    }

    static func readIntegrity() throws -> IntegrityRecord {
        try readData(account: integrityAccount) { cfData in
            try JSONDecoder().decode(IntegrityRecord.self, from: cfData as Data)
        }
    }

    static func deleteAll() {
        SecItemDelete(baseQuery(passwordAccount) as CFDictionary)
        SecItemDelete(baseQuery(integrityAccount) as CFDictionary)
    }
}

/// Checks a password against the local directory with the OpenDirectory
/// framework (in-process; the password is never passed to another program).
enum PasswordVerifier {
    enum Result: Equatable {
        case valid
        case invalid
        case failed(String)
    }

    static func verify(_ password: String, user: String = NSUserName()) -> Result {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            // "dsRecTypeStandard:Users" == kODRecordTypeUsers (a C global that
            // Swift 6 strict concurrency rejects).
            let record = try node.record(withRecordType: "dsRecTypeStandard:Users", name: user, attributes: nil)
            try record.verifyPassword(password)
            return .valid
        } catch let error as NSError {
            if error.domain == ODFrameworkErrorDomain && error.code == Int(kODErrorCredentialsInvalid.rawValue) {
                return .invalid
            }
            return .failed(error.localizedDescription)
        }
    }
}
