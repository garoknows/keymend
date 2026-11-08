import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Supplies the key that encrypts the learned words.
public protocol LearningKeyProvider: Sendable {
    /// The existing key, or nil if there isn't one yet. Throws if it can't be read.
    func loadKey() throws -> SymmetricKey?
    func saveKey(_ key: SymmetricKey) throws
    func deleteKey() throws
}

public enum LearningVaultError: Error, Equatable {
    case keychain(Int32)
    /// There's a file, but it can't be opened with the key we have. It's left untouched.
    case cannotDecrypt
    case wrongPassphrase
    case notAnExport
}

/// Keeps the key in the login Keychain, on this Mac only.
public struct KeychainLearningKey: LearningKeyProvider {
    private let service: String
    private let account = "learning-key"

    public init(service: String = "io.github.garoknows.keymend.learning") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func loadKey() throws -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw LearningVaultError.keychain(status) }
        return SymmetricKey(data: data)
    }

    public func saveKey(_ key: SymmetricKey) throws {
        var q = query
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw LearningVaultError.keychain(status) }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LearningVaultError.keychain(status) }
    }
}

/// The only place Keymend writes files. It holds learned words, always encrypted: the store goes
/// to one file in the app's sandbox container, and exports go to a file the user picks.
public struct LearningVault: Sendable {
    public let fileURL: URL
    private let keys: LearningKeyProvider

    public init(fileURL: URL, keys: LearningKeyProvider) {
        self.fileURL = fileURL
        self.keys = keys
    }

    /// The store's location inside the app's sandbox container.
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("learning.keymend")
    }

    /// Reads the store. No file means an empty store. A file that can't be opened is an error,
    /// so a Keychain problem can never lead to overwriting the user's words.
    public func load() throws -> LearningStore {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LearningStore() }
        let sealed: Data
        do {
            sealed = try Data(contentsOf: fileURL)
        } catch {
            throw LearningVaultError.cannotDecrypt
        }
        guard let key = try keys.loadKey() else { throw LearningVaultError.cannotDecrypt }
        do {
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
            return try JSONDecoder().decode(LearningStore.self, from: opened)
        } catch {
            throw LearningVaultError.cannotDecrypt
        }
    }

    /// Encrypts and writes the store, replacing the file in one step.
    public func save(_ store: LearningStore) throws {
        let key: SymmetricKey
        if let existing = try keys.loadKey() {
            key = existing
        } else {
            key = SymmetricKey(size: .bits256)
            try keys.saveKey(key)
        }
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(store), using: key)
        guard let combined = sealed.combined else { throw LearningVaultError.cannotDecrypt }
        // Replace the file in one step, so a crash can't leave half a file behind.
        let temporary = fileURL.appendingPathExtension("tmp")
        try combined.write(to: temporary)
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Deletes the file and the key.
    public func destroy() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try keys.deleteKey()
    }

    // MARK: Export and import (encrypted with a passphrase, for moving to another Mac)

    private static let magic = Data("KEYMEND-LEARNING-1".utf8)
    public static let rounds: UInt32 = 600_000
    /// How much key work an imported file may ask for. A file asking for more could freeze the
    /// Mac for minutes; one asking for less was never made by Keymend.
    public static let allowedRounds: ClosedRange<UInt32> = 100_000...2_000_000

    public static func writeExport(_ store: LearningStore, passphrase: String, to url: URL, rounds: UInt32 = LearningVault.rounds) throws {
        // Written straight to the chosen file: the sandbox allows that file and nothing beside it.
        try exportData(store, passphrase: passphrase, rounds: rounds).write(to: url)
    }

    public static func readExport(from url: URL, passphrase: String) throws -> LearningStore {
        try store(fromExport: Data(contentsOf: url), passphrase: passphrase)
    }

    static func exportData(_ store: LearningStore, passphrase: String, rounds: UInt32 = LearningVault.rounds) throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw LearningVaultError.keychain(status) }
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(store), using: key)
        guard let combined = sealed.combined else { throw LearningVaultError.notAnExport }
        var header = magic
        withUnsafeBytes(of: rounds.bigEndian) { header.append(contentsOf: $0) }
        return header + salt + combined
    }

    static func store(fromExport data: Data, passphrase: String) throws -> LearningStore {
        let bytes = Data(data)
        let saltStart = magic.count + 4
        guard bytes.count > saltStart + 16, bytes.prefix(magic.count) == magic else { throw LearningVaultError.notAnExport }
        let rounds = bytes[magic.count..<saltStart].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard allowedRounds.contains(rounds) else { throw LearningVaultError.notAnExport }
        let salt = bytes[saltStart..<(saltStart + 16)]
        let key = try derive(passphrase, salt: Data(salt), rounds: rounds)
        do {
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes[(saltStart + 16)...]), using: key)
            return try JSONDecoder().decode(LearningStore.self, from: opened)
        } catch {
            throw LearningVaultError.wrongPassphrase
        }
    }

    private static func derive(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        guard status == kCCSuccess else { throw LearningVaultError.wrongPassphrase }
        return SymmetricKey(data: out)
    }
}
