import CryptoKit
import Darwin
import Foundation
import Security

@MainActor
final class PersonalizationStore {
    private struct WritingEntry: Codable {
        let text: String
        let appID: String
        let domain: String?
    }

    private struct History: Codable {
        let version: Int
        let entries: [WritingEntry]
    }

    private struct Scope: Hashable {
        let appID: String
        let domain: String?
    }

    private static let keyService = "app.freecomplete.accepted-history.v1"
    private static let keyAccount = "local-encryption-key"
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")
    private let directory: URL
    private let file: URL
    private var entries: [WritingEntry] = []
    private var canAppend = true
    private var vocabularyCache: [Scope: String] = [:]

    // The nonthrowing public contract still exposes every storage failure.
    // In particular, a corrupt or inaccessible file is never replaced by an
    // apparently empty history when the next completion is accepted.
    private(set) var lastError: String?
    var count: Int { entries.count }

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FreeComplete", isDirectory: true)
        file = directory.appendingPathComponent("accepted-history.aesgcm")
        do {
            entries = try load()
        } catch {
            canAppend = false
            lastError = "Could not read encrypted writing history: \(error.localizedDescription)"
        }
    }

    func vocabulary(appID: String, domain: String?) -> String {
        guard !appID.isEmpty else { return "" }
        let scope = Scope(appID: appID, domain: domain)
        if let cached = vocabularyCache[scope] { return cached }
        var terms: [String: (spelling: String, frequency: Int, recent: Int)] = [:]
        for (index, entry) in entries.enumerated() where entry.appID == appID && entry.domain == domain {
            entry.text.enumerateSubstrings(in: entry.text.startIndex..<entry.text.endIndex, options: .byWords) { word, _, _, _ in
                guard let word, (3...40).contains(word.count) else { return }
                let normalized = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Self.normalizationLocale)
                guard !Self.commonWords.contains(normalized) else { return }
                if var current = terms[normalized] {
                    current.frequency += 1
                    current.recent = index
                    terms[normalized] = current
                } else {
                    terms[normalized] = (word, 1, index)
                }
            }
        }
        let ranked = terms.values.sorted {
            if $0.frequency != $1.frequency { return $0.frequency > $1.frequency }
            if $0.recent != $1.recent { return $0.recent > $1.recent }
            return $0.spelling < $1.spelling
        }
        var result = ""
        for term in ranked.prefix(48) {
            if result.count + term.spelling.count + 2 > 600 { break }
            if !result.isEmpty { result += ", " }
            result += term.spelling
        }
        vocabularyCache[scope] = result
        return result
    }

    func recordWriting(text: String, appID: String, domain: String?) {
        guard canAppend else { return } // lastError from failed load remains visible.
        guard !appID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Writing and its app identifier must not be empty."
            return
        }
        do {
            let key = try encryptionKey(createIfMissing: true)
            let entry = WritingEntry(text: String(text.suffix(200)), appID: appID, domain: domain)
            if let last = entries.last, last.text == entry.text && last.appID == appID && last.domain == domain { return }
            entries.append(entry)
            let evicted = entries.count > 2_000 ? entries.removeFirst() : nil
            do {
                let plaintext = try JSONEncoder().encode(History(version: 1, entries: entries))
                guard let sealed = try AES.GCM.seal(plaintext, using: key).combined else {
                    throw StoreError.invalidCiphertext
                }
                try saveAtomically(sealed)
            } catch {
                entries.removeLast()
                if let evicted { entries.insert(evicted, at: 0) }
                throw error
            }
            vocabularyCache.removeValue(forKey: Scope(appID: appID, domain: domain))
            lastError = nil
        } catch {
            lastError = "Could not save encrypted writing history: \(error.localizedDescription)"
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            entries.removeAll()
            vocabularyCache.removeAll()
            canAppend = true
            try deleteEncryptionKey()
            lastError = nil
        } catch {
            lastError = "Could not clear encrypted writing history: \(error.localizedDescription)"
        }
    }

    private func load() throws -> [WritingEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let ciphertext = try Data(contentsOf: file)
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else {
            throw StoreError.invalidCiphertext
        }
        let plaintext = try AES.GCM.open(box, using: encryptionKey(createIfMissing: false))
        let history = try JSONDecoder().decode(History.self, from: plaintext)
        guard history.version == 1 else { throw StoreError.unsupportedVersion }
        return history.entries
    }

    private func encryptionKey(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecSuccess {
            guard let bytes = value as? Data, bytes.count == 32 else { throw StoreError.invalidKey }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound && createIfMissing else { throw StoreError.keychain(status) }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw StoreError.keychain(randomStatus) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(bytes)
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        return SymmetricKey(data: bytes)
    }

    private func deleteEncryptionKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }

    private func saveAtomically(_ ciphertext: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw StoreError.posix(errno) }
        defer { temporary.path.withCString { _ = Darwin.unlink($0) } }
        var closed = false
        defer { if !closed { _ = Darwin.close(descriptor) } }
        try ciphertext.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let amount = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StoreError.posix(amount < 0 ? errno : EIO) }
                written += amount
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw StoreError.posix(errno) }
        let closeStatus = Darwin.close(descriptor)
        let closeError = errno
        closed = true
        guard closeStatus == 0 else { throw StoreError.posix(closeError) }
        let renameStatus = temporary.path.withCString { source in
            file.path.withCString { target in Darwin.rename(source, target) }
        }
        guard renameStatus == 0 else { throw StoreError.posix(errno) }
    }

    private enum StoreError: LocalizedError {
        case invalidCiphertext
        case invalidKey
        case unsupportedVersion
        case keychain(OSStatus)
        case posix(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidCiphertext: "History is damaged or is not an AES-GCM file."
            case .invalidKey: "The Keychain encryption key is invalid."
            case .unsupportedVersion: "This history was written by a newer app version."
            case let .keychain(status): "Keychain error \(status)."
            case let .posix(code): "File error \(code): \(String(cString: strerror(code)))."
            }
        }
    }

    private static let commonWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "been", "before", "being", "but",
        "can", "could", "does", "for", "from", "had", "has", "have", "her", "his",
        "into", "its", "just", "more", "not", "only", "other", "our", "out", "over",
        "really", "should", "some", "than", "that", "the", "their", "them", "there",
        "these", "they", "this", "those", "through", "too", "very", "was", "were",
        "what", "when", "where", "which", "while", "will", "with", "would", "you", "your"
    ]
}
