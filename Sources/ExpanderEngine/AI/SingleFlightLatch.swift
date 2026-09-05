/// Admits one holder at a time, refusing rather than queueing.
///
/// `PaletteToolRouter` and `SnippetTagSuggester` each declared a byte-identical private
/// `Latch` actor. They stay *separate instances* — palette routing and tag suggestion must
/// not contend with each other — but there is now one implementation of the rule.
///
/// Refusing is the point: a fast typist would otherwise stack model calls behind a latch
/// that queues, and every one of them would answer a query the user has already replaced.
///
/// Callers release explicitly on both paths rather than in a `defer`. A deferred release is
/// ordered *after* the caller resumes, so a second call made straight away found the latch
/// still held and was dropped as if the model were busy; `defer` cannot `await`, so the
/// release is spelled out instead.
public actor SingleFlightLatch {
    private var busy = false

    public init() {}

    /// `true` when the caller now holds the latch and must release it.
    public func acquire() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    public func release() { busy = false }
}
