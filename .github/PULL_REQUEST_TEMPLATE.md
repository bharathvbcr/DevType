## Description

<!-- Provide a brief summary of the changes and the rationale behind them. -->

Fixes # <!-- Link related issue(s) here, e.g. Fixes #123 -->

---

## Type of Change

- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] ⚡ Performance improvement
- [ ] 🔒 Security / Privacy enhancement
- [ ] 📝 Documentation update
- [ ] 🧪 Tests / CI improvement
- [ ] 🎨 UI / Styling refinement

---

## Invariants & Safety Checklist

- [ ] **Privacy Invariant**: No telemetry or analytics SDK was added. Any new network path is opt-in, off by default, and disclosed in the UI.
- [ ] **Secure Input Safety**: Event tap pausing / fail-closed behavior in password fields is preserved.
- [ ] **Secret Snippets**: Secret values remain absent from general storage, exports, and diagnostics.
- [ ] **MainActor Compliance**: All AppKit UI interactions execute on `@MainActor`.
- [ ] **Thread Safety**: Shared mutable state in `ExpanderEngine` is properly synchronized.

---

## Verification & Testing

- [ ] Added new unit tests covering the changes.
- [ ] Ran `./Scripts/test.sh` — all unit tests pass locally.
- [ ] Ran `./Scripts/ci-local.sh` — linting, build, and packaging pass cleanly.
- [ ] Verified manually on macOS (describe testing environment below):

<!-- Note how you manually verified this change (e.g. tested expansion in TextEdit/VS Code). -->
