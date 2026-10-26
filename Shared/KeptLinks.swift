import Foundation
import HyperVaultKit

extension KeptItem {
    /// The `hypervault://` link that opens this in the app. Keys have none: a key is never a link,
    /// a search result or something a widget shows.
    var appLink: URL? {
        switch kind {
        case .page, .file, .group:
            guard let slug else { return nil }
            return URL(string: "hypervault://artifact/\(slug)")
        case .memory:
            return URL(string: "hypervault://memory/\(id)")
        case .key:
            return nil
        }
    }
}
