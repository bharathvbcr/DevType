# Unreleased reliability fixes

- Delayed expansion actions share cancellation and target checks through paste, modifier gaps, cursor movement and trailing keys. Superseded work cannot intentionally continue posting input.
- Text, image and secret clipboard publication check every write against the original ownership count. Failed publication never schedules a paste; recovery replaces partial contents only while DevType still owns the clipboard.
- Delivery confirmation requires a relevant transition in the original field and range. Existing text, Unicode case-fold shifts and inconclusive timeouts remain unverified and never trigger automatic corrective replay.
- Library conflict recovery validates and verifies adoption before removing captured alternate versions. Recovery copies and a phase journal are retained; adoption failure and pending cleanup have separate UI outcomes.
- Macro preparation has an explicit operation context. UUID, random and counter values stay fixed across fill-in delays, counter writes persist in order, and the expansion lab injects its prepared result once. Cursor anchors survive both syntaxes and Unicode transformations; clipboard and fill-in values remain literal.
- Clipboard deadlines use monotonic time, invalid copy timing is refused before posting, and transcript comparison has explicit input, token and matrix-work limits with cancellation.

Local validation on September 4, 2026: 2,777 tests passed with zero failures or skips, including the five opt-in audit benchmarks; 42 CI script/plist/release-wrapper checks passed; debug and optimized release builds passed. Native tests use isolated pasteboards and temporary file versions. Physical cross-application focus/Secure Input races and live iCloud conflicts remain unverified. This working-tree update has not been packaged, installed or released.
