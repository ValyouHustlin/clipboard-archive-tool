// Prints the base64 Ed25519 public key for a base64 32-byte seed read from
// the file named in the first argument (Sparkle's private key file format).
// release.sh uses it to prove a key file matches the public key it builds
// in; the update test uses it for its throwaway scratch key.
import CryptoKit
import Foundation

let path = CommandLine.arguments[1]
let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: text), seed.count == 32 else {
    FileHandle.standardError.write(Data("not a base64 32-byte seed\n".utf8))
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
