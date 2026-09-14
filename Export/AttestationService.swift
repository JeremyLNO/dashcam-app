import CryptoKit
import DeviceCheck
import Foundation

/// Signs a recording's digest with a key Apple vouches for.
///
/// This is the only part of the chain that answers the question metadata cannot: **was
/// this file produced by this app?** A field saying "recorded with Dashcam Pocket" is
/// written by anyone in ten seconds. A private key shipped inside the app is no better —
/// it can be extracted, and whoever extracts it signs whatever they like.
///
/// App Attest gets around that because the key never exists outside the Secure Enclave,
/// and Apple issues a certificate saying: *this key belongs to a genuine instance of this
/// app, on a genuine Apple device.* Signing the video's SHA-256 with it produces something
/// a third party can check without trusting us — they verify the certificate chain against
/// Apple's own root, then the signature against the digest they compute from the file.
///
/// What it does **not** prove: that the pixels show what they appear to show. It ties a
/// file to an app and a device, nothing more. Saying otherwise would be the kind of claim
/// that collapses the first time it is examined.
@MainActor
final class AttestationService: ObservableObject {
    enum Failure: LocalizedError {
        case unsupported
        case attestationFailed(String)
        case assertionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return L10n.t("attest.error.unsupported")
            case .attestationFailed(let detail), .assertionFailed(let detail): return detail
            }
        }
    }

    /// The receipt that travels with an exported file.
    struct Receipt: Codable {
        /// Base64 of the CBOR attestation object: the certificate chain, rooted in Apple.
        /// Written once per key, and repeated in every receipt so each export can be
        /// checked on its own without hunting for an earlier one.
        let attestation: String
        /// Base64 of the CBOR assertion: the signature over this particular digest.
        let assertion: String
        /// The key's identifier, as Apple issued it.
        let keyID: String
        /// What was signed — the SHA-256 of the file, hex, so a verifier can recompute it.
        let digest: String
        let signedAt: Date
        /// Named so nobody has to guess how to check this.
        let verification: String
    }

    @Published private(set) var isAvailable = DCAppAttestService.shared.isSupported

    private let service = DCAppAttestService.shared
    private let keychainAccount = "attest.keyID"
    private var cachedAttestation: Data?

    /// Signs one digest, attesting the key first if this device has never done so.
    ///
    /// The digest doubles as App Attest's challenge. With no server of our own to issue a
    /// nonce, binding the assertion to the very thing being signed is what keeps it from
    /// being replayed onto another file — there is exactly one file whose SHA-256 is this.
    func sign(digest: Data) async throws -> Receipt {
        guard service.isSupported else { throw Failure.unsupported }

        let keyID: String
        if let existing = try await existingKeyID() {
            keyID = existing
        } else {
            keyID = try await generateAndAttest(digest: digest)
        }
        let clientDataHash = Data(SHA256.hash(data: digest))

        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Failure.assertionFailed(error.localizedDescription)
        }

        let attestation = try await attestationObject(for: keyID, clientDataHash: clientDataHash)

        return Receipt(
            attestation: attestation.base64EncodedString(),
            assertion: assertion.base64EncodedString(),
            keyID: keyID,
            digest: digest.map { String(format: "%02x", $0) }.joined(),
            signedAt: Date(),
            verification: "Apple App Attest. Verify the attestation chain against Apple's App Attest root CA, then the assertion signature over SHA-256(digest). See docs/CERTIFICATION.md."
        )
    }

    // MARK: - Key handling

    private func existingKeyID() async throws -> String? {
        guard let stored = Keychain.read(account: keychainAccount),
              let keyID = String(data: stored, encoding: .utf8),
              !keyID.isEmpty
        else { return nil }
        return keyID
    }

    private func generateAndAttest(digest: Data) async throws -> String {
        do {
            let keyID = try await service.generateKey()
            // Attestation is the one network call in the chain, and the only one: it goes
            // to Apple, carries a hash, and never a frame of video.
            let clientDataHash = Data(SHA256.hash(data: digest))
            let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            cachedAttestation = attestation
            Keychain.write(Data(keyID.utf8), account: keychainAccount)
            AttestationStore.save(attestation: attestation, for: keyID)
            return keyID
        } catch {
            throw Failure.attestationFailed(error.localizedDescription)
        }
    }

    /// The attestation object, from memory, from disk, or by attesting a fresh key.
    ///
    /// A key can only be attested once; the object is therefore kept, because every
    /// receipt needs it to stand on its own.
    private func attestationObject(for keyID: String, clientDataHash: Data) async throws -> Data {
        if let cachedAttestation { return cachedAttestation }
        if let stored = AttestationStore.load(for: keyID) {
            cachedAttestation = stored
            return stored
        }
        // A key whose attestation was lost is a key nobody can check: start again rather
        // than hand out an assertion with nothing to anchor it.
        Keychain.delete(account: keychainAccount)
        let keyID = try await generateAndAttest(digest: clientDataHash)
        guard let attestation = AttestationStore.load(for: keyID) else {
            throw Failure.attestationFailed("attestation could not be stored")
        }
        return attestation
    }
}

/// Where the attestation object lives between exports.
enum AttestationStore {
    private static var directory: URL {
        StorageLocations.applicationSupport.appendingPathComponent("attestation", isDirectory: true)
    }

    static func save(attestation: Data, for keyID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? attestation.write(to: directory.appendingPathComponent(filename(for: keyID)), options: .atomic)
    }

    static func load(for keyID: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(filename(for: keyID)))
    }

    /// A key id is base64 and can carry `/`, which is a path separator: hashing it keeps
    /// the filename flat and stable.
    static func filename(for keyID: String) -> String {
        Data(SHA256.hash(data: Data(keyID.utf8))).map { String(format: "%02x", $0) }.joined() + ".attest"
    }
}

/// The smallest keychain wrapper that does the job: one string, read, written, deleted.
enum Keychain {
    private static let service = "dashcam.lno.company.attest"

    static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(_ data: Data, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // The key id is useless to anyone else and pointless to sync: it names a key
            // that exists in one Secure Enclave and nowhere else.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
