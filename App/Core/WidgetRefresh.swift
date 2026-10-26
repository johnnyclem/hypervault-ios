import WidgetKit

/// Tells the Home Screen and Lock Screen widgets that what is kept has changed, so they read it again
/// instead of waiting for their next scheduled refresh.
enum WidgetRefresh {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
