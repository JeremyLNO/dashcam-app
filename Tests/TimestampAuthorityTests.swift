import XCTest
@testable import Dashcam

/// The RFC 3161 encoder, checked against bytes this app did not produce.
///
/// The request is DER, hand-encoded: exactly the kind of code that looks right and is
/// wrong by one byte. So the expected bytes come from `openssl ts -query -sha256 -cert
/// -no_nonce`, run against a public authority that granted the token — the encoder is
/// therefore measured against something that already worked, not against my reading of
/// the spec.
final class TimestampAuthorityTests: XCTestCase {
    /// SHA-256 of the five bytes "preuve\n", stamped by freetsa.org on 2026-09-14.
    private let digestHex = "a0f1eb8ce90313aa49eb82eb25067f12368d2d23128d9fa55dacb09c670a1ce7"
    private let opensslRequestHex = "30390201013031300d060960864801650304020105000420"
        + "a0f1eb8ce90313aa49eb82eb25067f12368d2d23128d9fa55dacb09c670a1ce7"
        + "0101ff"

    private func data(fromHex hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    func testTheRequestIsByteIdenticalToOpenSSLs() {
        let request = TimestampAuthority.requestBody(digest: data(fromHex: digestHex))
        XCTAssertEqual(request.map { String(format: "%02x", $0) }.joined(), opensslRequestHex)
    }

    /// The length byte is where a hand-written encoder breaks first.
    func testTheRequestAnnouncesItsOwnLength() {
        let request = TimestampAuthority.requestBody(digest: data(fromHex: digestHex))
        XCTAssertEqual(request.first, 0x30, "a TimeStampReq is a SEQUENCE")
        XCTAssertEqual(Int(request[1]), request.count - 2, "the declared length must match what follows")
    }

    /// A granted response, as returned by the authority.
    func testAGrantedResponseIsRecognised() {
        // SEQUENCE { SEQUENCE { INTEGER 0 } ... } — the shape of a granted status.
        let granted = data(fromHex: "3082121c30030201003082121306092a864886f70d010702")
        XCTAssertTrue(TimestampAuthority.isGranted(granted))
    }

    /// Rejection arrives with HTTP 200 and a status of 2 or more. Reading the status is
    /// the only way to tell it from success, and skipping that check would file a refusal
    /// as evidence.
    func testARejectedResponseIsNotMistakenForATimestamp() {
        let rejected = data(fromHex: "30820020300b0201020404deadbeef0201")
        XCTAssertFalse(TimestampAuthority.isGranted(rejected))
    }

    func testGarbageIsRefusedRatherThanParsed() {
        XCTAssertFalse(TimestampAuthority.isGranted(Data()))
        XCTAssertFalse(TimestampAuthority.isGranted(data(fromHex: "deadbeef")))
        XCTAssertFalse(TimestampAuthority.isGranted(data(fromHex: "3003020100")), "too short to carry a token")
    }
}
