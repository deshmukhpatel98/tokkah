// Signs a file with the release key and prints the base64 Ed25519 signature.
//
// The key is read from ~/.config/tokkah/mac-update-ed25519.key and MUST NOT ever
// live in this repo: the repo is AGPL-published, so committed means published,
// and a published signing key means anyone can ship an update to every machine
// that has ever run this binary.
//
//   swift sign.swift <file>   ->   base64 signature on stdout
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else { FileHandle.standardError.write("usage: sign <file>\n".data(using: .utf8)!); exit(2) }
let keyPath = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".config/tokkah/mac-update-ed25519.key")
guard let hex = try? String(contentsOf: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
  FileHandle.standardError.write("cannot read \(keyPath.path)\n".data(using: .utf8)!); exit(1)
}
var raw = Data(); var i = hex.startIndex
while i < hex.endIndex {
  let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
  guard let b = UInt8(hex[i..<j], radix: 16) else { FileHandle.standardError.write("bad key hex\n".data(using: .utf8)!); exit(1) }
  raw.append(b); i = j
}
guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let data = FileManager.default.contents(atPath: args[1]),
      let sig = try? key.signature(for: data) else {
  FileHandle.standardError.write("sign failed\n".data(using: .utf8)!); exit(1)
}
print(sig.base64EncodedString())
