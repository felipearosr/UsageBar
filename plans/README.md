# Implementation plans

| Plan | Priority | Dependencies | Status |
|---|---|---|---|
| [001: GNOME popup performance](001-linux-popup-performance.md) | P1 | None | DONE |

The user selected popup improvements 1–3 and authorized subagent implementation. Discovery uses Luna medium, coding uses Luna max (highest supported Luna setting), review uses Astra high. Backend, Tauri, and Settings changes are deferred to keep this change focused on popup responsiveness.

Implemented and integrated without a commit. Astra's source-review fixes are applied; final real-GNOME tests verify opening/reuse, reorder controls, value updates, detail invalidation, teardown, cancellation, and disable/re-enable. Five pure helper tests, JS syntax, and whitespace checks pass. Repository-wide checks remain unavailable here because `swift` and `plutil` are missing.
