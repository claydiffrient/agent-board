import SwiftUI

/// Reads a SwiftUI `@State` property's seeded value off a freshly-constructed, never-mounted view
/// value, through `Mirror` — the substitute for reading a rendered `Picker`'s `NSPopUpButton` on
/// macOS 27, where that control no longer constructs at all offscreen (see the headless UI
/// verification note). Only reaching the private `_name` field needs reflection; `State.wrappedValue`
/// and the extraction below are both public API once we're holding the concretely-typed box.
///
/// This only reflects the `init(initialValue:)` value. Once a view is mounted, SwiftUI moves a
/// `@State` property's storage into the live render graph, and reflecting the original struct copy
/// stops finding it (measured: returns `nil` after mounting). So this is for "does the sheet seed
/// its state correctly", never for state a mounted view's `.task` or a user action later changed.
@MainActor
func seededState<Root, Value>(_ root: Root, _ name: String, as type: Value.Type = Value.self) -> Value? {
    guard let field = Mirror(reflecting: root).children.first(where: { $0.label == name })?.value else {
        return nil
    }
    if let boxed = field as? State<Value> {
        return boxed.wrappedValue
    }
    // A `@State` whose declared type is `Optional` compiles to `LazyState<Value>` rather than
    // `State<Value>` on this toolchain (measured); its payload sits one level deeper, in a
    // `_storage` enum case, reachable only by reflection all the way down.
    guard let storage = Mirror(reflecting: field).children.first(where: { $0.label == "_storage" })?.value
    else { return nil }
    return Mirror(reflecting: storage).children.first?.value as? Value
}
