import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A model on the person's own network (Ollama, LM Studio, any server that
// speaks the OpenAI chat protocol), called by the phone itself.
//
// Connected models (`/api/backends`) are called by HyperVault's server, which
// refuses addresses that only mean something on one network (a home Ollama on
// 192.168.x.x), so those need a tunnel. A local model skips the server for the
// call: the phone asks the model directly, and the turn goes through the same
// context -> generate -> save steps as a model on the phone (`OnDeviceChat`).
// Nothing here holds a key; a model that needs one is a connected model.

public struct ChatLocalModel: Sendable, Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// The API root: `http://192.168.1.20:11434/v1`.
    public var baseURL: String
    /// The model to ask for: `llama3.3`.
    public var model: String
    /// How many tokens the runtime reads at once. Ollama's default is small, and
    /// what the server sends as context is trimmed to fit.
    public var contextTokens: Int

    public static let defaultContextTokens = 4_096

    public init(
        id: String = UUID().uuidString, name: String = "", baseURL: String, model: String,
        contextTokens: Int = ChatLocalModel.defaultContextTokens
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.contextTokens = contextTokens
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model : trimmed
    }

    /// Characters of system prompt and history to hand the model: about 60% of
    /// its window at three characters a token, the rest left for its answer.
    public var contextBudget: Int { max(2_000, contextTokens * 18 / 10) }

    /// The address with a scheme, no trailing slash and the protocol's `/v1`
    /// root: what a person types ("192.168.1.20:11434") becomes
    /// `http://192.168.1.20:11434/v1`. A pasted `/chat/completions` is cut off.
    public static func normalizedBase(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        while text.hasSuffix("/") { text.removeLast() }
        if let components = URLComponents(string: text), components.path.isEmpty { text += "/v1" }
        return text
    }

    public var chatURL: URL? { endpoint("/chat/completions") }
    public var modelsURL: URL? { endpoint("/models") }

    private func endpoint(_ path: String) -> URL? {
        let base = Self.normalizedBase(baseURL)
        guard let host = URLComponents(string: base)?.host, !host.isEmpty else { return nil }
        return URL(string: base + path)
    }

    /// What is wrong with this model, in plain words, or nil when it is ready.
    public var problem: String? {
        let base = Self.normalizedBase(baseURL)
        guard !base.isEmpty, let components = URLComponents(string: base), let host = components.host, !host.isEmpty else {
            return "Enter the address of your model, like 192.168.1.20:11434."
        }
        if components.scheme == "http", !ChatBackendHints.isLocalAddress(base) {
            return "An address outside your own network needs https."
        }
        if components.scheme != "http", components.scheme != "https" { return "The address must start with http or https." }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name the model to ask for, like llama3.3." }
        if contextTokens < 512 { return "The context size is too small to be useful." }
        return nil
    }
}

/// Reading and writing the OpenAI chat protocol's streaming form.
public enum OpenAIChatStream {
    public enum Event: Sendable, Equatable {
        case text(String)
        case done
        case ignore
    }

    /// `POST {base}/chat/completions` with `stream: true`.
    public static func request(
        for local: ChatLocalModel, system: String, messages: [ChatWireMessage], timeout: TimeInterval = 180
    ) -> URLRequest? {
        guard let url = local.chatURL else { return nil }
        var wire: [JSONValue] = []
        let instructions = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty { wire.append(["role": "system", "content": .string(instructions)]) }
        for message in messages where message.role != .tool {
            wire.append(["role": .string(message.role.rawValue), "content": .string(message.content)])
        }
        let body: JSONValue = ["model": .string(local.model), "messages": .array(wire), "stream": true]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? HVCoding.encoder(.verbatim).encode(body)
        return request
    }

    /// One line of the event stream: `data: {"choices":[{"delta":{"content":"Hi"}}]}`.
    public static func event(fromLine line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .ignore
        }
        if let piece = json["choices"]?[0]?["delta"]?["content"]?.string, !piece.isEmpty { return .text(piece) }
        // Some runtimes answer a stream request with one whole message.
        if let whole = json["choices"]?[0]?["message"]?["content"]?.string, !whole.isEmpty { return .text(whole) }
        return .ignore
    }

    /// A refusal's own sentence, from `{"error":{"message":"..."}}` or `{"error":"..."}`.
    public static func errorMessage(fromBody data: Data, status: Int, host: String) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let text = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string, !text.isEmpty {
                return "\(host) said: \(text)"
            }
        }
        switch status {
        case 404: return "\(host) doesn't know that model, or the address is missing its /v1."
        case 401, 403: return "\(host) wants a key. A model that needs one is connected under Your models instead."
        default: return "\(host) answered with an error (\(status))."
        }
    }

    /// The model names in `GET {base}/models`.
    public static func modelNames(fromList data: Data) -> [String] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return (json["data"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
    }

    /// What a network failure means to the person.
    public static func explain(_ error: URLError, host: String) -> String {
        // -1022: App Transport Security refused a plain http address outside the local network.
        if error.code.rawValue == -1022 { return "\(host) needs https unless it is on your own network." }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            return "Couldn't reach \(host). Is the model running, and is this iPhone on the same network?"
        case .timedOut:
            return "\(host) didn't answer in time. A model that is still loading can be slow the first time."
        default:
            return error.localizedDescription
        }
    }
}

/// A `ChatModelProvider` for a local model. How lines arrive (URLSession's
/// byte stream on a phone, a fake in tests) is up to `lines`; it throws
/// `OnDeviceChatError` for a refusal it can put in words.
public struct OpenAICompatibleProvider: ChatModelProvider {
    public let local: ChatLocalModel
    let lines: @Sendable (URLRequest) -> AsyncThrowingStream<String, Error>

    public init(local: ChatLocalModel, lines: @escaping @Sendable (URLRequest) -> AsyncThrowingStream<String, Error>) {
        self.local = local
        self.lines = lines
    }

    public var modelName: String { local.model }
    public var contextBudget: Int { local.contextBudget }

    public func generate(system: String, messages: [ChatWireMessage]) -> AsyncThrowingStream<String, Error> {
        let local = self.local
        let lines = self.lines
        let request = OpenAIChatStream.request(for: local, system: system, messages: messages)
        let host = request?.url?.host ?? local.baseURL
        return AsyncThrowingStream { continuation in
            guard let request else {
                continuation.finish(throwing: OnDeviceChatError.generation("That address isn't one this iPhone can call."))
                return
            }
            let task = Task {
                var text = ""
                do {
                    for try await line in lines(request) {
                        switch OpenAIChatStream.event(fromLine: line) {
                        case .text(let piece):
                            text += piece
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as OnDeviceChatError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    if error.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: OnDeviceChatError.generation(OpenAIChatStream.explain(error, host: host)))
                    }
                } catch {
                    continuation.finish(throwing: OnDeviceChatError.generation(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
