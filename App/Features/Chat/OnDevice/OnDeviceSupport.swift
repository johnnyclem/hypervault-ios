import HyperVaultKit
import SwiftUI

/// Whether this phone can write chat replies itself, said in plain words.
struct ChatOnDeviceStatus: Equatable {
    var isAvailable: Bool
    /// One sentence: why it is on, or what to do to turn it on.
    var explanation: String

    static let ready = ChatOnDeviceStatus(
        isAvailable: true,
        explanation: "Replies are written on this iPhone. Your messages stay here until they are saved to your vault."
    )

    static func unavailable(_ explanation: String) -> ChatOnDeviceStatus {
        ChatOnDeviceStatus(isAvailable: false, explanation: explanation)
    }
}

/// The seam between chat and the system's on-device model. The Kit runs the
/// turn (`OnDeviceChat`); this says whether there is a model to run it with.
/// Tests and previews swap in their own.
struct ChatOnDeviceSupport {
    var status: () -> ChatOnDeviceStatus
    var makeProvider: () -> ChatModelProvider?
    /// Models on the person's own network, which the phone calls directly.
    var localModels: () -> [ChatLocalModel] = { [] }
    var makeLocalProvider: (ChatLocalModel) -> ChatModelProvider? = { _ in nil }

    static let system = ChatOnDeviceSupport(
        status: { ChatOnDeviceModels.status() },
        makeProvider: { ChatOnDeviceModels.provider() },
        localModels: { ChatLocalModelStore.load() },
        makeLocalProvider: { OpenAICompatibleProvider(local: $0, lines: { ChatURLSessionLines.lines(for: $0) }) }
    )

    static func fixed(
        _ status: ChatOnDeviceStatus, provider: ChatModelProvider? = nil,
        localModels: [ChatLocalModel] = [], localProvider: ChatModelProvider? = nil
    ) -> ChatOnDeviceSupport {
        ChatOnDeviceSupport(
            status: { status }, makeProvider: { provider },
            localModels: { localModels }, makeLocalProvider: { _ in localProvider }
        )
    }
}

/// Apple's availability check can say the on-device model is ready while the
/// safety-guardrail asset it needs is not on the phone. Generation then fails
/// inside the model catalog (`com.apple.fm.language.safety_guardrail`,
/// UnifiedAssetFramework 5000) and the raw text is not something to show.
enum OnDeviceModelAssets {
    static let explanation = "The on-device model isn't on this iPhone yet, even though Apple Intelligence is on. In Settings, under Apple Intelligence & Siri, stay on Wi-Fi until it finishes downloading, then try again."

    static func isMissing(_ error: Error) -> Bool {
        var parts = [String(describing: error), error.localizedDescription]
        if let debug = error as? CustomDebugStringConvertible {
            parts.append(debug.debugDescription)
        }
        let ns = error as NSError
        parts.append(ns.domain)
        if let reason = ns.localizedFailureReason { parts.append(reason) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            parts.append(String(describing: underlying))
            parts.append(underlying.localizedDescription)
        }
        let blob = parts.joined(separator: "\n").lowercased()
        return blob.contains("safety_guardrail")
            || blob.contains("modelcatalog")
            || blob.contains("unifiedassetframework")
            || blob.contains("no underlying assets")
            || blob.contains("assetsunavailable")
    }
}

enum ChatOnDeviceModels {
    /// What the title says wherever the on-device model is named.
    static let title = "On this iPhone"
    static let subtitle = "Apple Intelligence"

    static let needsNewerSystem = "On-device chat needs iOS 26 or later with Apple Intelligence."

    /// Said once in the composer while the on-device model is chosen: it has no tools.
    static let toolFreeLine = "Answering on this iPhone. Tools need a connected model."

    static func status() -> ChatOnDeviceStatus {
        #if canImport(FoundationModels)
        return ChatFoundationModelsAdapter.status()
        #else
        return .unavailable(needsNewerSystem)
        #endif
    }

    static func provider() -> ChatModelProvider? {
        #if canImport(FoundationModels)
        if ChatFoundationModelsAdapter.status().isAvailable {
            return ChatFoundationModelsProvider()
        }
        #endif
        return nil
    }
}
