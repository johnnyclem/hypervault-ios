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

    static let system = ChatOnDeviceSupport(
        status: { ChatOnDeviceModels.status() },
        makeProvider: { ChatOnDeviceModels.provider() }
    )

    static func fixed(_ status: ChatOnDeviceStatus, provider: ChatModelProvider? = nil) -> ChatOnDeviceSupport {
        ChatOnDeviceSupport(status: { status }, makeProvider: { provider })
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
        if #available(iOS 26.0, *) {
            return ChatFoundationModelsAdapter.status()
        }
        #endif
        return .unavailable(needsNewerSystem)
    }

    static func provider() -> ChatModelProvider? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), ChatFoundationModelsAdapter.status().isAvailable {
            return ChatFoundationModelsProvider()
        }
        #endif
        return nil
    }
}
