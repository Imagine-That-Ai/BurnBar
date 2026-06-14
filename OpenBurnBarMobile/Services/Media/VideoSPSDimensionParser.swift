import Foundation
import CoreMedia

// remediation(1080p-decoder): real SPS/VPS dimension extraction for the
// raw-payload decode fallback. When a keyframe arrives WITHOUT an `OBVCFG1`
// `VideoDecoderConfigurationPayload` (so VideoToolbox cannot derive the true
// size from explicit parameter sets), we attempt to parse the SPS NAL out of
// the raw bitstream and compute the real luma WxH. On any parse failure the
// caller keeps its documented, overridable default — this helper NEVER throws
// and NEVER crashes; it returns `nil` and the caller fails soft.
//
// Framing: the raw sample payload may be either AVCC/HVCC (4-byte big-endian
// length-prefixed NAL units, as VideoToolbox emits) OR Annex B (00 00 01 /
// 00 00 00 01 start codes). The NAL scanner below detects and walks both so the
// fallback works regardless of how the sender framed an SPS-bearing keyframe.
//
// Correctness notes (worked examples used as test oracles in comments):
//   * H.264 1080p SPS body (after the 0x67 NAL header), emulation-prevented:
//       67 64 00 28 ac d9 40 78 02 27 e5 84 00 00 03 00 04 ...
//     decodes to 1920x1080 (16 MB cropping on height: 120 MB units * 16 = 1920
//     wide path, 1080 via frame_crop_bottom = 4 -> 1088 - 8 = 1080).
//   * HEVC 1080p SPS yields pic_width_in_luma_samples=1920,
//     pic_height_in_luma_samples=1080 directly (no conformance crop) or
//     1920x1088 with conf_win_bottom_offset=4 (chroma 4:2:0 -> *2 = 8 luma
//     rows cropped -> 1080).

/// Stateless helper: parse real luma dimensions from raw H.264/HEVC NAL data.
/// All entry points are total (no throws); malformed input yields `nil`.
enum VideoSPSDimensionParser {
    /// Codec selector matching `VideoReceivePipeline.Codec` without coupling to it.
    enum Codec {
        case h264
        case hevc
    }

    /// Attempts to extract real dimensions from the raw NAL payload. Returns
    /// `nil` when no parsable SPS is found or the bitstream is malformed/short,
    /// so the caller can fall back to its documented default.
    static func dimensions(from payload: Data, codec: Codec) -> CMVideoDimensions? {
        switch codec {
        case .h264:
            guard let sps = firstNALUnit(in: payload, matching: { ($0 & 0x1F) == 7 }) else {
                return nil
            }
            return parseH264(sps: sps)
        case .hevc:
            // HEVC NAL header is 2 bytes; type is bits 1..6 of the first byte.
            guard let sps = firstNALUnit(in: payload, matching: { (($0 >> 1) & 0x3F) == 33 }) else {
                return nil
            }
            return parseHEVC(sps: sps)
        }
    }

    // MARK: - NAL scanning (handles both Annex B and AVCC/HVCC framing)

    /// Returns the first NAL unit (header byte + RBSP, start code / length prefix
    /// stripped) whose header byte satisfies `matches`. Tries Annex B start codes
    /// first; if none are present, falls back to 4-byte length-prefixed parsing.
    private static func firstNALUnit(
        in payload: Data,
        matching matches: (UInt8) -> Bool
    ) -> [UInt8]? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }

        if let units = annexBNALUnits(bytes), !units.isEmpty {
            if let match = units.first(where: { matches($0.first ?? 0) }) {
                return match
            }
            // Start codes were present but no matching NAL — do not also try the
            // length-prefixed interpretation (it would misparse Annex B data).
            return nil
        }

        return lengthPrefixedFirstNALUnit(bytes, matching: matches)
    }

    /// Splits an Annex B stream on 3- or 4-byte start codes. Returns `nil` when
    /// no start code is found (so the caller can try length-prefixed framing).
    private static func annexBNALUnits(_ bytes: [UInt8]) -> [[UInt8]]? {
        var starts: [Int] = []
        var i = 0
        let n = bytes.count
        while i + 2 < n {
            if bytes[i] == 0x00, bytes[i + 1] == 0x00, bytes[i + 2] == 0x01 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return nil }

        var units: [[UInt8]] = []
        units.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            // The next NAL begins at the next start code; trim its leading 0x00
            // (the 4-byte start code 00 00 00 01 is a 3-byte code preceded by a
            // zero byte, which we conservatively leave attached to the prior NAL
            // and strip here by scanning back is unnecessary for the SPS header).
            let endExclusive: Int
            if index + 1 < starts.count {
                // starts[index+1] points just past the next 00 00 01; back up to
                // the start of that start code (3 bytes), then drop a possible
                // leading zero of a 4-byte code.
                var nextCode = starts[index + 1] - 3
                if nextCode > start, bytes[nextCode - 1] == 0x00 {
                    nextCode -= 1
                }
                endExclusive = nextCode
            } else {
                endExclusive = n
            }
            guard endExclusive > start else { continue }
            units.append(Array(bytes[start..<endExclusive]))
        }
        return units
    }

    /// Walks 4-byte big-endian length-prefixed NAL units (AVCC/HVCC) and returns
    /// the first NAL whose header byte matches. Guards every length against the
    /// buffer bounds.
    private static func lengthPrefixedFirstNALUnit(
        _ bytes: [UInt8],
        matching matches: (UInt8) -> Bool
    ) -> [UInt8]? {
        var offset = 0
        let n = bytes.count
        while offset + 4 <= n {
            let length =
                (Int(bytes[offset]) << 24) |
                (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) |
                Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= n else { return nil }
            let unit = Array(bytes[offset..<(offset + length)])
            if matches(unit.first ?? 0) {
                return unit
            }
            offset += length
        }
        return nil
    }

    // MARK: - H.264 SPS

    /// Parses an H.264 SPS NAL (header byte + RBSP). Returns real luma WxH or
    /// `nil` on any inconsistency. Implements pic_width/height in MB units,
    /// frame_mbs_only_flag, chroma_format_idc, and frame_cropping.
    private static func parseH264(sps: [UInt8]) -> CMVideoDimensions? {
        // Drop the 1-byte NAL header; the rest is the RBSP with emulation bytes.
        guard sps.count > 1 else { return nil }
        let reader = BitReader(removingEmulationPrevention: Array(sps[1...]))

        guard let profileIDC = reader.readBits(8) else { return nil }
        // constraint_set flags + reserved (8) and level_idc (8).
        guard reader.skipBits(8), reader.readBits(8) != nil else { return nil }
        guard reader.readUE() != nil else { return nil } // seq_parameter_set_id

        var chromaFormatIDC: UInt32 = 1 // default 4:2:0 when not signalled
        // High-profile family carries chroma_format_idc and bit-depth fields.
        if profileIDC == 100 || profileIDC == 110 || profileIDC == 122 ||
            profileIDC == 244 || profileIDC == 44 || profileIDC == 83 ||
            profileIDC == 86 || profileIDC == 118 || profileIDC == 128 ||
            profileIDC == 138 || profileIDC == 139 || profileIDC == 134 ||
            profileIDC == 135 {
            guard let chroma = reader.readUE() else { return nil }
            chromaFormatIDC = chroma
            if chromaFormatIDC == 3 {
                guard reader.skipBits(1) else { return nil } // separate_colour_plane_flag
            }
            guard reader.readUE() != nil else { return nil } // bit_depth_luma_minus8
            guard reader.readUE() != nil else { return nil } // bit_depth_chroma_minus8
            guard reader.skipBits(1) else { return nil } // qpprime_y_zero_transform_bypass_flag
            guard let seqScalingMatrixPresent = reader.readBit() else { return nil }
            if seqScalingMatrixPresent {
                let listCount = (chromaFormatIDC != 3) ? 8 : 12
                for index in 0..<listCount {
                    guard let present = reader.readBit() else { return nil }
                    if present {
                        let size = index < 6 ? 16 : 64
                        guard skipH264ScalingList(reader, size: size) else { return nil }
                    }
                }
            }
        }

        guard reader.readUE() != nil else { return nil } // log2_max_frame_num_minus4
        guard let picOrderCntType = reader.readUE() else { return nil }
        if picOrderCntType == 0 {
            guard reader.readUE() != nil else { return nil } // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            guard reader.skipBits(1) != false else { return nil } // delta_pic_order_always_zero_flag
            guard reader.readSE() != nil else { return nil } // offset_for_non_ref_pic
            guard reader.readSE() != nil else { return nil } // offset_for_top_to_bottom_field
            guard let cycleLength = reader.readUE() else { return nil }
            // Bound the loop against malformed huge counts.
            guard cycleLength <= 256 else { return nil }
            for _ in 0..<cycleLength {
                guard reader.readSE() != nil else { return nil } // offset_for_ref_frame[i]
            }
        }

        guard reader.readUE() != nil else { return nil } // max_num_ref_frames
        guard reader.skipBits(1) else { return nil } // gaps_in_frame_num_value_allowed_flag

        guard let widthMBsMinus1 = reader.readUE() else { return nil }
        guard let heightMapUnitsMinus1 = reader.readUE() else { return nil }
        guard let frameMBsOnly = reader.readBit() else { return nil }
        if !frameMBsOnly {
            guard reader.skipBits(1) else { return nil } // mb_adaptive_frame_field_flag
        }
        guard reader.skipBits(1) else { return nil } // direct_8x8_inference_flag

        guard let croppingFlag = reader.readBit() else { return nil }
        var cropLeft: UInt32 = 0
        var cropRight: UInt32 = 0
        var cropTop: UInt32 = 0
        var cropBottom: UInt32 = 0
        if croppingFlag {
            guard let left = reader.readUE(),
                  let right = reader.readUE(),
                  let top = reader.readUE(),
                  let bottom = reader.readUE() else {
                return nil
            }
            cropLeft = left
            cropRight = right
            cropTop = top
            cropBottom = bottom
        }

        // Compute luma dimensions in samples.
        let widthInMBs = UInt64(widthMBsMinus1) + 1
        let heightInMapUnits = UInt64(heightMapUnitsMinus1) + 1
        let rawWidth = widthInMBs * 16
        // map units are frame map units only when frame_mbs_only_flag == 1.
        let rawHeight = (2 - (frameMBsOnly ? UInt64(1) : UInt64(0))) * heightInMapUnits * 16

        // Crop units depend on chroma subsampling (subWidthC/subHeightC).
        // 4:2:0 (idc 1): subW=2 subH=2; 4:2:2 (idc 2): subW=2 subH=1;
        // 4:4:4 (idc 3): subW=1 subH=1; monochrome (idc 0): subW=subH=1.
        let cropUnitX: UInt64
        let cropUnitY: UInt64
        switch chromaFormatIDC {
        case 0:
            cropUnitX = 1
            cropUnitY = 2 - (frameMBsOnly ? 1 : 0)
        case 2:
            cropUnitX = 2
            cropUnitY = 2 - (frameMBsOnly ? 1 : 0)
        case 3:
            cropUnitX = 1
            cropUnitY = 2 - (frameMBsOnly ? 1 : 0)
        default: // 4:2:0
            cropUnitX = 2
            cropUnitY = 2 * (2 - (frameMBsOnly ? 1 : 0))
        }

        let cropX = (UInt64(cropLeft) + UInt64(cropRight)) * cropUnitX
        let cropY = (UInt64(cropTop) + UInt64(cropBottom)) * cropUnitY
        guard rawWidth > cropX, rawHeight > cropY else { return nil }
        let width = rawWidth - cropX
        let height = rawHeight - cropY

        return sanitize(width: width, height: height)
    }

    /// Skips an H.264 scaling list of `size` coefficients (8x8 or 16x16). Returns
    /// false on truncation.
    private static func skipH264ScalingList(_ reader: BitReader, size: Int) -> Bool {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                guard let deltaScale = reader.readSE() else { return false }
                nextScale = (lastScale + Int(deltaScale) + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
        }
        return true
    }

    // MARK: - HEVC SPS

    /// Parses an HEVC SPS NAL (2-byte header + RBSP). Returns real luma WxH after
    /// applying the conformance window, or `nil` on malformed input.
    private static func parseHEVC(sps: [UInt8]) -> CMVideoDimensions? {
        // Drop the 2-byte NAL header.
        guard sps.count > 2 else { return nil }
        let reader = BitReader(removingEmulationPrevention: Array(sps[2...]))

        guard reader.skipBits(4) else { return nil } // sps_video_parameter_set_id
        guard let maxSubLayersMinus1 = reader.readBits(3) else { return nil }
        guard reader.skipBits(1) else { return nil } // sps_temporal_id_nesting_flag

        // profile_tier_level( 1, sps_max_sub_layers_minus1 )
        guard skipHEVCProfileTierLevel(reader, maxSubLayersMinus1: Int(maxSubLayersMinus1)) else {
            return nil
        }

        guard reader.readUE() != nil else { return nil } // sps_seq_parameter_set_id
        guard let chromaFormatIDC = reader.readUE() else { return nil }
        if chromaFormatIDC == 3 {
            guard reader.skipBits(1) else { return nil } // separate_colour_plane_flag
        }

        guard let picWidth = reader.readUE() else { return nil }  // pic_width_in_luma_samples
        guard let picHeight = reader.readUE() else { return nil } // pic_height_in_luma_samples

        guard let confWindowFlag = reader.readBit() else { return nil }
        var leftOffset: UInt32 = 0
        var rightOffset: UInt32 = 0
        var topOffset: UInt32 = 0
        var bottomOffset: UInt32 = 0
        if confWindowFlag {
            guard let left = reader.readUE(),
                  let right = reader.readUE(),
                  let top = reader.readUE(),
                  let bottom = reader.readUE() else {
                return nil
            }
            leftOffset = left
            rightOffset = right
            topOffset = top
            bottomOffset = bottom
        }

        // Conformance window offsets are in chroma sample units; scale by
        // subWidthC/subHeightC. 4:2:0 -> 2/2, 4:2:2 -> 2/1, 4:4:4 & mono -> 1/1.
        let subWidthC: UInt64
        let subHeightC: UInt64
        switch chromaFormatIDC {
        case 1: subWidthC = 2; subHeightC = 2 // 4:2:0
        case 2: subWidthC = 2; subHeightC = 1 // 4:2:2
        default: subWidthC = 1; subHeightC = 1 // 4:4:4 or monochrome
        }

        let cropX = (UInt64(leftOffset) + UInt64(rightOffset)) * subWidthC
        let cropY = (UInt64(topOffset) + UInt64(bottomOffset)) * subHeightC
        let rawWidth = UInt64(picWidth)
        let rawHeight = UInt64(picHeight)
        guard rawWidth > cropX, rawHeight > cropY else { return nil }
        return sanitize(width: rawWidth - cropX, height: rawHeight - cropY)
    }

    /// Skips the HEVC profile_tier_level() structure for the general layer plus
    /// any present sub-layer profile/level fields. Returns false on truncation.
    private static func skipHEVCProfileTierLevel(
        _ reader: BitReader,
        maxSubLayersMinus1: Int
    ) -> Bool {
        // general: profile_space(2) tier(1) profile_idc(5) = 8 bits,
        // profile_compatibility_flags(32), then the constraint/reserved block
        // and general_level_idc(8): 8 + 32 + 48 + 8 = 96 bits total.
        guard reader.skipBits(8) else { return false }
        guard reader.skipBits(32) else { return false }
        guard reader.skipBits(48) else { return false } // constraint flags + reserved
        guard reader.skipBits(8) else { return false }  // general_level_idc

        guard maxSubLayersMinus1 <= 7 else { return false }
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        profilePresent.reserveCapacity(maxSubLayersMinus1)
        levelPresent.reserveCapacity(maxSubLayersMinus1)
        for _ in 0..<maxSubLayersMinus1 {
            guard let p = reader.readBit(), let l = reader.readBit() else { return false }
            profilePresent.append(p)
            levelPresent.append(l)
        }
        if maxSubLayersMinus1 > 0 {
            // reserved_zero_2bits for layers [maxSubLayersMinus1, 8).
            for _ in maxSubLayersMinus1..<8 {
                guard reader.skipBits(2) else { return false }
            }
        }
        for index in 0..<maxSubLayersMinus1 {
            if profilePresent[index] {
                // sub_layer profile block mirrors the general 88-bit block
                // (without the trailing level_idc): 8 + 32 + 48 = 88 bits.
                guard reader.skipBits(8), reader.skipBits(32), reader.skipBits(48) else {
                    return false
                }
            }
            if levelPresent[index] {
                guard reader.skipBits(8) else { return false } // sub_layer_level_idc
            }
        }
        return true
    }

    // MARK: - Shared

    /// Clamps parsed values into the Int32 range and rejects non-positive or
    /// implausibly large dimensions (defends against a misparse that walked off
    /// into garbage bits).
    private static func sanitize(width: UInt64, height: UInt64) -> CMVideoDimensions? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            return nil
        }
        return CMVideoDimensions(width: Int32(width), height: Int32(height))
    }
}

/// Minimal MSB-first bit reader over an RBSP with emulation-prevention bytes
/// (`00 00 03`) already removed at construction. All reads are bounds-checked
/// and return `nil` past the end — the parser treats that as a soft failure.
final class BitReader {
    private let bytes: [UInt8]
    private var bitPosition = 0

    /// Builds a reader, stripping H.264/HEVC emulation-prevention bytes: a `0x03`
    /// that follows two consecutive `0x00` bytes is removed so the decoded RBSP
    /// matches the encoder's pre-escaping bitstream.
    init(removingEmulationPrevention raw: [UInt8]) {
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(raw.count)
        var zeroRun = 0
        for byte in raw {
            if zeroRun >= 2, byte == 0x03 {
                // Drop the emulation-prevention byte and reset the run; the next
                // byte starts fresh per the spec (00 00 03 xx -> 00 00 xx).
                zeroRun = 0
                continue
            }
            cleaned.append(byte)
            zeroRun = (byte == 0x00) ? (zeroRun + 1) : 0
        }
        self.bytes = cleaned
    }

    /// Reads a single bit as a Bool, or `nil` past the end.
    func readBit() -> Bool? {
        guard let value = readBits(1) else { return nil }
        return value == 1
    }

    /// Reads `count` bits (0...32) MSB-first into a UInt32, or `nil` past the end.
    func readBits(_ count: Int) -> UInt32? {
        guard count >= 0, count <= 32 else { return nil }
        guard count > 0 else { return 0 }
        guard bitPosition + count <= bytes.count * 8 else { return nil }
        var result: UInt32 = 0
        for _ in 0..<count {
            let byteIndex = bitPosition >> 3
            let bitIndex = 7 - (bitPosition & 7)
            let bit = (bytes[byteIndex] >> bitIndex) & 1
            result = (result << 1) | UInt32(bit)
            bitPosition += 1
        }
        return result
    }

    /// Advances past `count` bits, returning false if that would overrun.
    @discardableResult
    func skipBits(_ count: Int) -> Bool {
        guard count >= 0, bitPosition + count <= bytes.count * 8 else { return false }
        bitPosition += count
        return true
    }

    /// Reads an unsigned Exp-Golomb code (ue(v)). Returns `nil` on overrun or an
    /// implausibly long prefix (guards against runaway parsing on garbage).
    func readUE() -> UInt32? {
        var leadingZeroBits = 0
        while true {
            guard let bit = readBit() else { return nil }
            if bit { break }
            leadingZeroBits += 1
            // ue values beyond 31 leading zeros cannot fit a 32-bit result and
            // almost always indicate a misparse; bail out softly.
            if leadingZeroBits > 31 { return nil }
        }
        if leadingZeroBits == 0 { return 0 }
        guard let suffix = readBits(leadingZeroBits) else { return nil }
        // (2^leadingZeroBits - 1) + suffix
        let base = (UInt32(1) << leadingZeroBits) - 1
        return base &+ suffix
    }

    /// Reads a signed Exp-Golomb code (se(v)) mapped from ue(v).
    func readSE() -> Int32? {
        guard let codeNum = readUE() else { return nil }
        if codeNum == 0 { return 0 }
        // k = ceil(codeNum/2), sign alternates: +,-,+,-...
        let magnitude = Int64((codeNum + 1) >> 1)
        return Int32((codeNum & 1) == 1 ? magnitude : -magnitude)
    }
}
