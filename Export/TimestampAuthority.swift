import Foundation

/// Anchors a recording's digest in time, by someone other than the phone.
///
/// Everything else in the chain is dated by the device, and a device's clock is set by
/// whoever holds it. That is the weak link an opposing party attacks first: the file is
/// intact, it was produced by the app — and nothing says it was produced *before* the
/// accident rather than after it.
///
/// RFC 3161 closes that. A Time-Stamping Authority signs a statement saying "this digest
/// was presented to me at this instant", and its signature is checkable against its own
/// certificate. The authority never sees the video: it receives 32 bytes of hash, from
/// which nothing can be reconstructed.
///
/// Verification needs no special tool:
/// ```
/// openssl ts -verify -data drive.mov -in drive.tsr -CAfile tsa-chain.pem
/// ```
enum TimestampAuthority {
    /// FreeTSA, the authority used by default: public, free, and its certificate is
    /// published. Nothing here is tied to it — any RFC 3161 endpoint works, and the URL is
    /// deliberately a parameter so an insurer's own authority can be used instead.
    static let defaultURL = URL(string: "https://freetsa.org/tsr")!

    enum Failure: LocalizedError {
        case badResponse(Int)
        case rejected
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return L10n.t("timestamp.error.http", code)
            case .rejected: return L10n.t("timestamp.error.rejected")
            case .transport(let detail): return detail
            }
        }
    }

    /// Asks the authority to stamp a digest, and hands back its token verbatim.
    ///
    /// The token is stored exactly as received: re-encoding it, or keeping only the parts
    /// that seemed useful, would break the signature covering it.
    static func stamp(digest: Data, url: URL = defaultURL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(digest: digest)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.badResponse(http.statusCode)
        }
        // A response that grants nothing still arrives as a 200 with a status inside it.
        guard isGranted(data) else { throw Failure.rejected }
        return data
    }

    /// Builds the DER for a `TimeStampReq` over a SHA-256 digest.
    ///
    /// Hand-encoded rather than pulled from a dependency, because the structure is fixed
    /// and tiny: a version, the hash with its algorithm, and a flag asking the authority
    /// to include its certificate so the token can be checked without fetching anything.
    ///
    /// ```
    /// TimeStampReq ::= SEQUENCE {
    ///   version        INTEGER { v1(1) },
    ///   messageImprint MessageImprint,
    ///   certReq        BOOLEAN DEFAULT FALSE }
    /// ```
    /// No nonce: it protects against a replayed *response*, which matters when a client
    /// asks repeatedly for the same digest. Here each digest is unique to one file, and
    /// leaving it out keeps the request byte-identical to what `openssl ts -query
    /// -no_nonce` produces — which is how this encoder is tested.
    static func requestBody(digest: Data) -> Data {
        precondition(digest.count == 32, "the request encoder is written for SHA-256")

        // AlgorithmIdentifier: OID 2.16.840.1.101.3.4.2.1 (sha256) followed by NULL.
        let sha256OID = Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
        let algorithm = sequence(sha256OID + Data([0x05, 0x00]))
        let imprint = sequence(algorithm + octetString(digest))
        let version = Data([0x02, 0x01, 0x01])
        let certReq = Data([0x01, 0x01, 0xFF])
        return sequence(version + imprint + certReq)
    }

    /// The response's `PKIStatus`: 0 is granted, 1 is granted with modifications.
    static func isGranted(_ response: Data) -> Bool {
        // TimeStampResp ::= SEQUENCE { status PKIStatusInfo, timeStampToken ... }
        // PKIStatusInfo ::= SEQUENCE { status INTEGER, ... }
        // So the status integer is the first primitive inside the second sequence.
        let bytes = [UInt8](response)
        guard bytes.count > 8, bytes[0] == 0x30 else { return false }
        guard let outer = contentStart(bytes, at: 0) else { return false }
        guard bytes.count > outer, bytes[outer] == 0x30 else { return false }
        guard let statusInfo = contentStart(bytes, at: outer) else { return false }
        guard bytes.count > statusInfo + 2, bytes[statusInfo] == 0x02 else { return false }
        let length = Int(bytes[statusInfo + 1])
        guard length == 1, bytes.count > statusInfo + 2 else { return false }
        return bytes[statusInfo + 2] <= 1
    }

    // MARK: - DER

    private static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    private static func octetString(_ content: Data) -> Data {
        Data([0x04]) + length(content.count) + content
    }

    /// DER length: short form under 128, long form above, which is all this encoder ever
    /// needs — the whole request is under a hundred bytes.
    private static func length(_ value: Int) -> Data {
        if value < 0x80 { return Data([UInt8(value)]) }
        if value <= 0xFF { return Data([0x81, UInt8(value)]) }
        return Data([0x82, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Index of the first content byte of the TLV starting at `index`.
    private static func contentStart(_ bytes: [UInt8], at index: Int) -> Int? {
        guard bytes.count > index + 1 else { return nil }
        let first = bytes[index + 1]
        if first < 0x80 { return index + 2 }
        let count = Int(first & 0x7F)
        guard count > 0, bytes.count > index + 1 + count else { return nil }
        return index + 2 + count
    }
}
