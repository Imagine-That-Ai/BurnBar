import XCTest
@testable import OpenBurnBarMedia

final class VideoDecoderConfigurationPayloadTests: XCTestCase {
    func testRoundTripCarriesParameterSetsAndSamplePayload() throws {
        let payload = VideoDecoderConfigurationPayload(
            codec: .hevc,
            parameterSets: [
                Data([0x40, 0x01, 0x0c]),
                Data([0x42, 0x01, 0x01, 0x60]),
                Data([0x44, 0x01])
            ],
            samplePayload: Data([0x00, 0x00, 0x00, 0x02, 0x26, 0x01])
        )

        let decoded = try XCTUnwrap(try VideoDecoderConfigurationPayload.decodeIfPresent(payload.encoded()))

        XCTAssertEqual(decoded.codec, .hevc)
        XCTAssertEqual(decoded.parameterSets, payload.parameterSets)
        XCTAssertEqual(decoded.samplePayload, payload.samplePayload)
    }

    func testDecodeIgnoresPlainVideoPayloads() throws {
        let plainPayload = Data([0x00, 0x00, 0x00, 0x02, 0x02, 0x01])

        XCTAssertNil(try VideoDecoderConfigurationPayload.decodeIfPresent(plainPayload))
    }

    func testTruncatedConfigurationPayloadFails() {
        var encoded = VideoDecoderConfigurationPayload.magic
        encoded.append(VideoDecoderConfigurationPayload.Codec.hevc.rawValue)

        XCTAssertThrowsError(try VideoDecoderConfigurationPayload.decodeIfPresent(encoded))
    }
}
