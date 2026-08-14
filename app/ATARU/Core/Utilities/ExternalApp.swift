import UIKit

/// Another app on the phone that ATARU hands a job to rather than doing badly
/// itself.
///
/// The rule is the same one that kept Jellyfin, Navidrome and Vaultwarden as
/// status cards instead of half-reimplementations: these are full products,
/// and the honest native treatment is to open the real client. What changed is
/// that a card saying "use the Jellyfin app" is only good advice if something
/// actually takes you there.
///
/// ## Querying a scheme is not free
///
/// `canOpenURL` answers `false` for ANY scheme not listed in
/// `LSApplicationQueriesSchemes` — silently, and identically to the app not
/// being installed. So every case here must have its scheme in Info.plist, or
/// the app it points at becomes permanently invisible.
enum ExternalApp: String, CaseIterable {
    /// Swiftfin, the official open-source Jellyfin client for iOS. The scheme
    /// is the one Swiftfin registers in its own Info.plist as a URL type with
    /// role Editor - checked against the source rather than assumed, because a
    /// wrong guess here is indistinguishable from the app being absent.
    case swiftfin

    var scheme: String { rawValue }

    var displayName: String {
        switch self {
        case .swiftfin: return "Swiftfin"
        }
    }

    private var probeURL: URL? { URL(string: "\(scheme)://") }

    /// Whether the app is on this phone. False also when the scheme is missing
    /// from `LSApplicationQueriesSchemes`, which is why that list and this enum
    /// have to be kept in step.
    @MainActor
    var isInstalled: Bool {
        guard let probeURL else { return false }
        return UIApplication.shared.canOpenURL(probeURL)
    }

    /// Hands over to the app. Returns false without doing anything if it is
    /// not installed, so the caller can fall back to showing its own screen
    /// rather than sending the user to a dead end.
    @MainActor
    @discardableResult
    func open() -> Bool {
        guard let probeURL, UIApplication.shared.canOpenURL(probeURL) else { return false }
        UIApplication.shared.open(probeURL)
        return true
    }
}
