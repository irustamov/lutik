import Testing
import Foundation
import CLibArchive

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private func params(power: UInt32, salt: [UInt8] = [], iv: [UInt8] = []) -> kernir_7zaes_params {
    var p = kernir_7zaes_params()
    p.cycles_power = power
    withUnsafeMutableBytes(of: &p.salt) { for (i, b) in salt.enumerated() { $0[i] = b } }
    p.salt_size = salt.count
    withUnsafeMutableBytes(of: &p.iv) { for (i, b) in iv.enumerated() { $0[i] = b } }
    return p
}

private func saltBytes(_ p: kernir_7zaes_params) -> [UInt8] {
    var p = p
    return withUnsafeBytes(of: &p.salt) { Array($0.prefix(p.salt_size)) }
}
private func ivBytes(_ p: kernir_7zaes_params) -> [UInt8] {
    var p = p
    return withUnsafeBytes(of: &p.iv) { Array($0) }
}

private func derive(_ pw: String, salt: [UInt8], power: UInt32) -> String {
    var pp = params(power: power, salt: salt)
    var key = [UInt8](repeating: 0xEE, count: 32)
    let rc = kernir_7zaes_derive_key(&pp, pw, &key)
    #expect(rc == 0)
    return hex(key)
}

@Test func deriveKeyMatchesKnownVectors() {
    #expect(derive("pw", salt: [], power: 19) == "78b01adf255dc83fe8e93289738d3d375f406cbb862415b7f9acec74f70bd539")
    #expect(derive("пароль", salt: [], power: 19) == "f893790e92879fb6f62b3c199c127a27f1fc825159b36f3533f7b8b31bde8a68")
    #expect(derive("pw", salt: [1, 2], power: 6) == "012f6ca1e14ec309eb58bc03468db96e5395a35e1fb33c9afd8aaaa2d2620962")
    #expect(derive("pw", salt: [1, 2], power: 0x3F) == "0102700077" + String(repeating: "00", count: 27))
    #expect(derive("😀a", salt: [], power: 4) == "6ea3d63d1da6ded078fe6064d294c5af4c812206d07261c8376fe297b70d75ac")
}

@Test func deriveKeyRejectsInvalidUTF8() {
    var pp = params(power: 4)
    var key = [UInt8](repeating: 0, count: 32)
    let bad: [CChar] = [CChar(bitPattern: 0xC3), CChar(bitPattern: 0x28), 0]
    #expect(kernir_7zaes_derive_key(&pp, bad, &key) == -1)
}

@Test func parsePropsVariants() {
    var p = kernir_7zaes_params()
    #expect(kernir_7zaes_parse_props([0x13], 1, &p) == 0)
    #expect(p.cycles_power == 19 && p.salt_size == 0)
    #expect(ivBytes(p) == [UInt8](repeating: 0, count: 16))

    let iv = (0..<16).map { UInt8($0 + 1) }
    let withIV: [UInt8] = [0x53, 0x0F] + iv
    #expect(kernir_7zaes_parse_props(withIV, withIV.count, &p) == 0)
    #expect(p.cycles_power == 19 && p.salt_size == 0)
    #expect(ivBytes(p) == iv)

    let mixed: [UInt8] = [0xD3, 0x10, 0xA1, 0xA2, 0xB1]
    #expect(kernir_7zaes_parse_props(mixed, mixed.count, &p) == 0)
    #expect(p.salt_size == 2)
    #expect(saltBytes(p) == [0xA1, 0xA2])
    #expect(Array(ivBytes(p).prefix(2)) == [0xB1, 0])

    #expect(kernir_7zaes_parse_props(mixed, mixed.count - 1, &p) == -1)
    #expect(kernir_7zaes_parse_props([0x13, 0x00], 2, &p) == -1)
    #expect(kernir_7zaes_parse_props([0x19], 1, &p) == -2)
    #expect(kernir_7zaes_parse_props([0x3F], 1, &p) == 0)
}

@Test func encodePropsRoundTrips() {
    let iv = (0..<16).map { UInt8(0xA0 + $0) }
    var pp = params(power: 19, iv: iv)
    var buf = [UInt8](repeating: 0, count: 34)
    let n = kernir_7zaes_encode_props(&pp, &buf)
    #expect(n == 18)
    #expect(Array(buf.prefix(2)) == [0x53, 0x0F])
    var q = kernir_7zaes_params()
    #expect(kernir_7zaes_parse_props(buf, n, &q) == 0)
    #expect(q.cycles_power == 19 && q.salt_size == 0)
    #expect(ivBytes(q) == iv)
}

@Test func cbcRoundTripChainsAcrossCalls() {
    let key = [UInt8](0..<32)
    let iv = [UInt8](repeating: 7, count: 16)
    let plain = (0..<64).map { UInt8(($0 * 5 + 1) & 0xFF) }

    var enc = kernir_7zaes_cbc()
    #expect(kernir_7zaes_cbc_init(&enc, 1, key, iv) == 0)
    var cipher = [UInt8](repeating: 0, count: 64)
    #expect(kernir_7zaes_cbc_update(&enc, plain, 64, &cipher) == 0)
    kernir_7zaes_cbc_release(&enc)
    #expect(cipher != plain)

    var dec = kernir_7zaes_cbc()
    #expect(kernir_7zaes_cbc_init(&dec, 0, key, iv) == 0)
    var out = [UInt8](repeating: 0, count: 64)
    #expect(kernir_7zaes_cbc_update(&dec, cipher, 16, &out) == 0)
    out.withUnsafeMutableBufferPointer { b in
        #expect(cipher.withUnsafeBufferPointer { kernir_7zaes_cbc_update(&dec, $0.baseAddress! + 16, 48, b.baseAddress! + 16) } == 0)
    }
    kernir_7zaes_cbc_release(&dec)
    #expect(out == plain)

    var iv2 = iv; iv2[0] += 1
    var bad = kernir_7zaes_cbc()
    #expect(kernir_7zaes_cbc_init(&bad, 0, key, iv2) == 0)
    var out2 = [UInt8](repeating: 0, count: 64)
    #expect(kernir_7zaes_cbc_update(&bad, cipher, 64, &out2) == 0)
    kernir_7zaes_cbc_release(&bad)
    #expect(out2 != plain)
}
