import HatcheryKit

/// A terraform identifier folded from an app name: `ci-live` becomes `ci_live`.
///
/// The one place ScanKit derives a resource id or a file name from an app name. It delegates
/// to `DokkuProvider.identifier`, so the two never drift apart.
public func tofuIdentifier(for appName: String) -> String {
    DokkuProvider.identifier(appName)
}
