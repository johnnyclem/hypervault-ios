import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

final class ChatLocalModelTests: XCTestCase {
    func testAddressesAreNormalised() {
        XCTAssertEqual(ChatLocalModel.normalizedBase("192.168.1.20:11434"), "http://192.168.1.20:11434/v1")
        XCTAssertEqual(ChatLocalModel.normalizedBase(" http://mac.local:1234/v1/ "), "http://mac.local:1234/v1")
        XCTAssertEqual(ChatLocalModel.normalizedBase("https://llm.example.com/v1/chat/completions"), "https://llm.example.com/v1")
        XCTAssertEqual(ChatLocalModel.normalizedBase("http://10.0.0.5:8080/"), "http://10.0.0.5:8080/v1")
        XCTAssertEqual(ChatLocalModel.normalizedBase("   "), "")
        let model = ChatLocalModel(baseURL: "192.168.1.20:11434", model: "llama3.3")
        XCTAssertEqual(model.chatURL?.absoluteString, "http://192.168.1.20:11434/v1/chat/completions")
        XCTAssertEqual(model.modelsURL?.absoluteString, "http://192.168.1.20:11434/v1/models")
    }

    func testWhatIsWrong() {
        XCTAssertNil(ChatLocalModel(baseURL: "192.168.1.20:11434", model: "llama3.3").problem)
        XCTAssertNotNil(ChatLocalModel(baseURL: "", model: "x").problem)
        XCTAssertNotNil(ChatLocalModel(baseURL: "192.168.1.20", model: " ").problem)
        // ATS: plain http is only for the person's own network.
        XCTAssertEqual(ChatLocalModel(baseURL: "http://llm.example.com/v1", model: "x").problem, "An address outside your own network needs https.")
        XCTAssertNil(ChatLocalModel(baseURL: "https://llm.example.com/v1", model: "x").problem)
        XCTAssertNil(ChatLocalModel(baseURL: "http://studio.local:1234", model: "x").problem)
        XCTAssertNotNil(ChatLocalModel(baseURL: "ftp://192.168.1.2", model: "x").problem)
    }

    func testTheContextBudgetFollowsTheWindow() {
        XCTAssertEqual(ChatLocalModel(baseURL: "a", model: "m", contextTokens: 4_096).contextBudget, 7_372)
        XCTAssertEqual(ChatLocalModel(baseURL: "a", model: "m", contextTokens: 512).contextBudget, 2_000)
        XCTAssertGreaterThan(ChatLocalModel(baseURL: "a", model: "m", contextTokens: 32_768).contextBudget, 50_000)
    }

    func testTheRequestIsTheStreamingChatProtocol() throws {
        let model = ChatLocalModel(baseURL: "192.168.1.20:11434", model: "llama3.3")
        let request = try XCTUnwrap(OpenAIChatStream.request(
            for: model, system: "Be brief.",
            messages: [ChatWireMessage(role: .user, content: "hi"), ChatWireMessage(role: .tool, content: "dropped"), ChatWireMessage(role: .assistant, content: "hello"), ChatWireMessage(role: .user, content: "again")]
        ))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
        XCTAssertEqual(body["model"], "llama3.3")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["messages"]?.array?.map { $0["role"]?.string ?? "" }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(body["messages"]?[0]?["content"], "Be brief.")
        // No system prompt, no system message.
        let bare = try XCTUnwrap(OpenAIChatStream.request(for: model, system: "  ", messages: [ChatWireMessage(role: .user, content: "hi")]))
        let bareBody = try XCTUnwrap(bare.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
        XCTAssertEqual(bareBody["messages"]?.array?.count, 1)
    }

    func testEventLines() {
        XCTAssertEqual(OpenAIChatStream.event(fromLine: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), .text("Hel"))
        XCTAssertEqual(OpenAIChatStream.event(fromLine: #"data:{"choices":[{"delta":{"content":"lo"}}]}"#), .text("lo"))
        XCTAssertEqual(OpenAIChatStream.event(fromLine: "data: [DONE]"), .done)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignore)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: #"data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}"#), .ignore)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: ": keep-alive"), .ignore)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: ""), .ignore)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: "data: not json"), .ignore)
        XCTAssertEqual(OpenAIChatStream.event(fromLine: #"data: {"choices":[{"message":{"content":"Whole."}}]}"#), .text("Whole."))
    }

    func testRefusalsAreSaidInTheModelsWords() {
        XCTAssertEqual(
            OpenAIChatStream.errorMessage(fromBody: Data(#"{"error":{"message":"model 'x' not found"}}"#.utf8), status: 404, host: "studio.local"),
            "studio.local said: model 'x' not found"
        )
        XCTAssertEqual(
            OpenAIChatStream.errorMessage(fromBody: Data(#"{"error":"bad request"}"#.utf8), status: 400, host: "h"),
            "h said: bad request"
        )
        XCTAssertTrue(OpenAIChatStream.errorMessage(fromBody: Data(), status: 401, host: "h").contains("wants a key"))
        XCTAssertTrue(OpenAIChatStream.errorMessage(fromBody: Data("<html>".utf8), status: 502, host: "h").contains("502"))
        XCTAssertEqual(OpenAIChatStream.modelNames(fromList: Data(#"{"object":"list","data":[{"id":"qwen2.5"},{"id":"llama3.3"}]}"#.utf8)), ["llama3.3", "qwen2.5"])
        XCTAssertEqual(OpenAIChatStream.modelNames(fromList: Data("nope".utf8)), [])
    }

    func testTheProviderStreamsAWholeReplySoFarAndStopsAtDone() async throws {
        let model = ChatLocalModel(baseURL: "192.168.1.20:11434", model: "llama3.3")
        let provider = OpenAICompatibleProvider(local: model) { _ in
            AsyncThrowingStream { continuation in
                for line in [
                    #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, "",
                    #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#, "",
                    #"data: {"choices":[{"delta":{"content":"lo"}}]}"#, "",
                    "data: [DONE]",
                    #"data: {"choices":[{"delta":{"content":"never"}}]}"#,
                ] { continuation.yield(line) }
                continuation.finish()
            }
        }
        var seen: [String] = []
        for try await text in provider.generate(system: "", messages: [ChatWireMessage(role: .user, content: "hi")]) { seen.append(text) }
        XCTAssertEqual(seen, ["Hel", "Hello"])
        XCTAssertEqual(provider.modelName, "llama3.3")
    }

    func testTheProviderSaysWhyItFailed() async {
        let model = ChatLocalModel(baseURL: "192.168.1.20:11434", model: "llama3.3")
        let offline = OpenAICompatibleProvider(local: model) { _ in
            AsyncThrowingStream { $0.finish(throwing: URLError(.cannotConnectToHost)) }
        }
        do {
            for try await _ in offline.generate(system: "", messages: []) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                (error as? OnDeviceChatError),
                .generation("Couldn't reach 192.168.1.20. Is the model running, and is this iPhone on the same network?")
            )
        }
        let broken = OpenAICompatibleProvider(local: ChatLocalModel(baseURL: "", model: "x")) { _ in AsyncThrowingStream { $0.finish() } }
        do {
            for try await _ in broken.generate(system: "", messages: []) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertNotNil(error as? OnDeviceChatError)
        }
    }
}
