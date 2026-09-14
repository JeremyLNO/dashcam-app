# What a Dashcam Pocket recording can prove

Three independent layers, each answering a different question. They are worth nothing
without each other, and worth misrepresenting even less: an overstated claim is one an
opposing expert dismantles in front of everyone.

| Layer | Question it answers | What it is |
|---|---|---|
| Metadata inside the file | *What does this file say about itself?* | QuickTime fields + a timed track |
| SHA-256 in the manifest | *Has it changed since?* | `Dashcam_…_proof.json` |
| App Attest signature | *Did this app, on a real device, produce it?* | `…proof.receipt.json` |
| RFC 3161 timestamp | *Did it exist before that moment?* | `…proof.tsr` |

The last two are written only when **Settings ▸ Privacy ▸ Certify exports** is on. It is
off by default, because it is the one feature that uses the network — sending a
fingerprint, never a frame.

## 1. Metadata — a claim, not a proof

Every segment carries, in standard QuickTime fields any tool reads:

- creation date, in ISO 8601 with fractional seconds
- position at the start of the segment, ISO 6709
- make, model, and the app's name and version
- the drive's identifier, the camera, the segment index, the time zone
- a **timed metadata track**: position, speed and g-force, sample by sample

```bash
ffprobe -v quiet -print_format json -show_format -show_streams drive.mov
exiftool drive.mov
```

⚠️ Anyone can write the same fields. This layer makes a file *readable* by a stranger; it
does not make it *trustworthy*. Nothing in the app's wording should suggest otherwise.

## 2. Integrity — the manifest

`ProofManifest` lists every segment with its SHA-256, plus the drive's events and
positions. Recomputing a digest and finding a different value means the file changed.

```bash
shasum -a 256 drive.mov        # compare with the "sha256" field in the manifest
```

The manifest alone proves only that the files match *it*. What anchors the manifest itself
is below.

## 3. Origin — Apple App Attest

`…proof.receipt.json` contains, for the manifest's digest:

- `attestation`: base64 CBOR — the certificate chain, rooted in Apple's App Attest CA,
  stating that the key lives in the Secure Enclave of a genuine Apple device and belongs to
  a genuine instance of **this** app (bundle `dashcam.lno.company`, team `2E6D4Q69QB`).
- `assertion`: base64 CBOR — the signature made by that key over `SHA-256(digest)`.
- `digest`: what was signed, hex.

To verify:

1. Decode the CBOR attestation object; take the X.509 chain from `attStmt.x5c`.
2. Check the chain against **Apple's App Attest Root CA**
   (<https://www.apple.com/certificateauthority/private/>).
3. Check that the authenticator data's `rpIdHash` equals `SHA-256("2E6D4Q69QB.dashcam.lno.company")`.
4. Take the public key from the leaf certificate; verify `assertion.signature` over
   `SHA-256(authenticatorData ‖ clientDataHash)`, where `clientDataHash = SHA-256(digest)`.
5. Recompute the manifest's SHA-256 from the file you received and check it equals `digest`.

An app-embedded private key would prove nothing — it can be extracted. The point of App
Attest is precisely that the key never leaves the Secure Enclave and that **Apple**, not
us, vouches for it.

### What it does not prove

That the images show what they appear to show. It ties a file to an app and a device.
Nothing about a chain of custody, and nothing that stops someone filming a screen.

## 4. Time — RFC 3161

`…proof.tsr` is a timestamp token over the manifest's digest, issued by an independent
authority (FreeTSA by default). Without it, the only date is the phone's own, which is set
by whoever holds the phone.

```bash
openssl ts -reply -in drive_proof.tsr -text        # read it
openssl ts -verify -data drive_proof.json -in drive_proof.tsr -CAfile tsa-chain.pem
```

The authority's certificate chain is published by the authority itself; for FreeTSA it is
at <https://freetsa.org/tsr>.

## Legal weight

None of this is a "certification" with force of law. In France, as in most of Europe, a
court weighs evidence freely and may appoint an expert. What these four layers give that
expert is a file that is readable, verifiably unmodified, traceable to an app and a device,
and anchored in time by a third party — which is considerably more than a video handed over
on its own, and considerably less than a guarantee. Say exactly that, and no more.
