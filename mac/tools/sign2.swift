// The SECOND release signature: ECDSA P-256 over the same manifest bytes, with a
// private key that lives ONLY in the kin-signing keychain, marked non-extractable.
//
//   swift sign2.swift --pub                 -> hex X9.63 public key (65 bytes), for the clients
//   swift sign2.swift <file>                -> base64 DER ECDSA-SHA256 signature on stdout
//
// WHY. The Ed25519 release key is a plain file; whoever copies it can sign an
// update for every Mac and phone. This key cannot be copied off the machine by
// any keychain API (kSecAttrIsExtractable = false), so a stolen file is no
// longer enough -- the attacker must also run code on this Mac while the
// keychain is unlocked. The Secure Enclave would be stronger still, but a
// command-line tool cannot create enclave keys without an Apple-provisioned
// entitlement (errSecMissingEntitlement, measured 2026-09-03); this is the
// strongest thing a self-signed toolchain can hold. Clients (Update.swift,
// Update.kt) require BOTH signatures from 0.130.0 on. Older clients ignore
// manifest.json.sig2, so nothing is stranded.
//
// The key is created once, on first use, in the keychain named by KEYCHAIN_NAME
// (the same one release.sh unlocks). Losing that keychain means enrolling a new
// key and shipping its public half in a release signed by the old one FIRST --
// so back the keychain up, and enroll a second Mac soon.
import Foundation
import Security
import CryptoKit

let label = "kin-release-p256"
func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
let env = ProcessInfo.processInfo.environment
guard let kcName = env["KEYCHAIN_NAME"] else { die("KEYCHAIN_NAME not set -- source ~/.config/kin-signing/env") }
let kcPath = NSHomeDirectory() + "/Library/Keychains/" + kcName
var kc: SecKeychain?
guard SecKeychainOpen(kcPath, &kc) == errSecSuccess, let keychain = kc else { die("cannot open \(kcPath)") }

func findKey() -> SecKey? {
  let q: [String: Any] = [
    kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    kSecAttrLabel as String: label, kSecMatchSearchList as String: [keychain],
    kSecReturnRef as String: true,
  ]
  var item: CFTypeRef?
  return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? (item as! SecKey) : nil
}
func makeKey() -> SecKey {
  var err: Unmanaged<CFError>?
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits as String: 256,
    kSecAttrLabel as String: label,
    kSecUseKeychain as String: keychain,
    kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrIsExtractable as String: false,
                                    kSecAttrLabel as String: label],
  ]
  guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else { die("create failed: \(err!.takeRetainedValue())") }
  FileHandle.standardError.write("sign2: created NEW non-extractable P-256 key '\(label)' in \(kcName)\n".data(using: .utf8)!)
  return k
}
let key = findKey() ?? makeKey()
var err: Unmanaged<CFError>?
guard let pub = SecKeyCopyPublicKey(key), let pubData = SecKeyCopyExternalRepresentation(pub, &err) as Data? else { die("no public key") }
let args = CommandLine.arguments
if args.count == 2, args[1] == "--pub" { print(pubData.map { String(format: "%02x", $0) }.joined()); exit(0) }
guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { die("usage: sign2 --pub | sign2 <file>") }
guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, &err) as Data? else { die("sign failed: \(err!.takeRetainedValue())") }
// Prove it before printing it: the same check the clients run.
let pk = try! P256.Signing.PublicKey(x963Representation: pubData)
guard pk.isValidSignature(try! P256.Signing.ECDSASignature(derRepresentation: sig), for: data) else { die("self-verify failed") }
print(sig.base64EncodedString())
