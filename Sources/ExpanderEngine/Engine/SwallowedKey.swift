import CoreGraphics

/// §8.2: the four values that describe "the key the event tap ate on our behalf".
///
/// These used to travel as four separate parameters through nine signatures — `inject`,
/// `injectOnMain`, `injectSecureClipboardPasteOnMain`, the refuse path, `finishPasteDelivery`,
/// `restoreTriggerAfterFailedPaste`, and their mirrors in `EventTapEngine`
/// (`performDeferredExpand`, `finishDeferredInject`, `refuseAfterSwallow`). Every one of them now
/// takes this value, and `ErasePlan.forMatch` reads the two fields it needs from it. The pure
/// unit-count helpers (`eraseCount(…swallowedFinalKey:)`) keep their single Bool: they count, they
/// do not carry the key.
///
/// This also folds in `EventTapEngine.mustReinjectOnRefuse(didSwallow:)`, which is the single rule
/// that makes the swallow contract safe: the tap only returns `nil` for the trigger key after the
/// planner has synchronously said the expand may proceed, so a later refuse owes the user
/// that keystroke back while the target is unchanged. A changed erase context suppresses replay.
public struct SwallowedKey: Equatable {
    /// True when the event tap swallowed the final trigger key (`return nil` from the callback).
    public let didSwallow: Bool
    public let unicode: String
    public let keyCode: Int64
    public let flags: CGEventFlags

    public init(
        didSwallow: Bool,
        unicode: String = "",
        keyCode: Int64 = 0,
        flags: CGEventFlags = []
    ) {
        self.didSwallow = didSwallow
        self.unicode = unicode
        self.keyCode = keyCode
        self.flags = flags
    }

    /// Nothing was swallowed — explicit inject paths (hotkey, inline search, Test Expansion Lab).
    public static let notSwallowed = SwallowedKey(didSwallow: false)

    /// §8.2: `EventTapEngine.mustReinjectOnRefuse(didSwallow:)` is delegated to rather than
    /// duplicated, so the swallow contract keeps exactly one definition.
    public var mustReinjectOnRefuse: Bool {
        EventTapEngine.mustReinjectOnRefuse(didSwallow: didSwallow)
    }

    /// False when there is nothing to post back (no character and no key code).
    public var hasPayload: Bool {
        !unicode.isEmpty || keyCode != 0
    }
}
