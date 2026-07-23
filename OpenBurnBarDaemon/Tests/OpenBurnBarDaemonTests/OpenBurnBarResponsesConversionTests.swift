import XCTest
@testable import OpenBurnBarDaemon

final class OpenBurnBarResponsesConversionTests: XCTestCase {
    func testResponsesFallbackPreservesDataBackedPDFInputFile() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "vision-model",
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Read this"],
                    [
                        "type": "input_file",
                        "filename": "brief.pdf",
                        "file_data": "data:application/pdf;base64,JVBERi0xLjc="
                    ]
                ]
            ]]
        ])

        let converted = try BurnBarOpenAICompatibleProviderExecutor
            .chatCompletionsBodyFromResponsesRequest(body, modelID: "vision-model").0
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: converted) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let filePart = try XCTUnwrap(content.first(where: { $0["type"] as? String == "image_url" }))
        let imageURL = try XCTUnwrap(filePart["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:application/pdf;base64,JVBERi0xLjc=")
    }

    func testResponsesFallbackDropsUnresolvableFileID() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "vision-model",
            "input": [[
                "role": "user",
                "content": [["type": "input_file", "file_id": "file_123"]]
            ]]
        ])

        XCTAssertThrowsError(
            try BurnBarOpenAICompatibleProviderExecutor
                .chatCompletionsBodyFromResponsesRequest(body, modelID: "vision-model")
        ) { error in
            XCTAssertTrue(String(describing: error).contains("must include input text"))
        }
    }
}
