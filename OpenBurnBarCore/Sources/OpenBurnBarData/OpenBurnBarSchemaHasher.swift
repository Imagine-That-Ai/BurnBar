import Foundation

enum OpenBurnBarSchemaHasher {
    static func sha256Hex(_ data: Data) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            var hash = SHA256Context()
            hash.update(buffer)
            hash.finalize(into: &bytes)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct SHA256Context {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var bitCount: UInt64 = 0
    private var buffer: [UInt8] = []

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        bitCount &+= UInt64(bytes.count) * 8
        buffer.append(contentsOf: bytes)
        while buffer.count >= 64 {
            process(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
    }

    mutating func finalize(into output: inout [UInt8]) {
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 64 {
            process(Array(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
        output = state.flatMap { word in
            [
                UInt8((word >> 24) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8(word & 0xff)
            ]
        }
    }

    private mutating func process(_ chunk: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = (UInt32(chunk[j]) << 24)
                | (UInt32(chunk[j + 1]) << 16)
                | (UInt32(chunk[j + 2]) << 8)
                | UInt32(chunk[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for i in 0..<64 {
            let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}
