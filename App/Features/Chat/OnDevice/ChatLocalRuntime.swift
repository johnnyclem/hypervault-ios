import HyperVaultKit
import SwiftUI

/// The models on the person's own network, kept on this phone. They hold an
/// address and a model name and nothing secret, so UserDefaults is enough.
enum ChatLocalModelStore {
    static let key = "pref.chat.localModels"

    static func load(defaults: UserDefaults = .standard) -> [ChatLocalModel] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ChatLocalModel].self, from: data)) ?? []
    }

    static func save(_ models: [ChatLocalModel], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Lines of a streaming HTTP answer, read with URLSession. A refusal becomes
/// an `OnDeviceChatError` that says what the model said.
enum ChatURLSessionLines {
    static func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let host = request.url?.host ?? "That address"
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 4_096 { break }
                        }
                        throw OnDeviceChatError.generation(
                            OpenAIChatStream.errorMessage(fromBody: body, status: http.statusCode, host: host)
                        )
                    }
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks a model what it can run: `GET {base}/models`.
    static func modelNames(for local: ChatLocalModel) async throws -> [String] {
        guard let url = local.modelsURL else { throw OnDeviceChatError.generation(local.problem ?? "That address isn't usable.") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw OnDeviceChatError.generation(OpenAIChatStream.errorMessage(fromBody: data, status: http.statusCode, host: url.host ?? "That address"))
            }
            return OpenAIChatStream.modelNames(fromList: data)
        } catch let error as URLError {
            throw OnDeviceChatError.generation(OpenAIChatStream.explain(error, host: url.host ?? "That address"))
        }
    }
}
