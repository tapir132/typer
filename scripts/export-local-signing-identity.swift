#!/usr/bin/env swift
import Foundation
import Security

guard let passphrase = ProcessInfo.processInfo.environment["TYPER_P12_PASSWORD"], !passphrase.isEmpty else {
    fputs("TYPER_P12_PASSWORD is required\n", stderr)
    exit(2)
}

let query = [
    kSecClass as String: kSecClassIdentity,
    kSecReturnRef as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll
] as CFDictionary
var result: CFTypeRef?
guard SecItemCopyMatching(query, &result) == errSecSuccess,
      let identities = result as? [SecIdentity] else {
    fputs("No code-signing identities were found\n", stderr)
    exit(1)
}

guard let identity = identities.first(where: { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate else { return false }
    return SecCertificateCopySubjectSummary(certificate) as String? == "Cadence Signing"
}) else {
    fputs("Cadence Signing identity was not found\n", stderr)
    exit(1)
}

let passphraseValue = passphrase as CFString
var parameters = SecItemImportExportKeyParameters(
    version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
    flags: [],
    passphrase: Unmanaged.passUnretained(passphraseValue),
    alertTitle: nil,
    alertPrompt: nil,
    accessRef: nil,
    keyUsage: nil,
    keyAttributes: nil
)
var exported: CFData?
let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
guard status == errSecSuccess, let exported else {
    fputs("Could not export signing identity (OSStatus \(status))\n", stderr)
    exit(1)
}

FileHandle.standardOutput.write(exported as Data)
