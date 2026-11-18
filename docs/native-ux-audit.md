# Native readability and progressive disclosure audit

Source audit of the main window and Preferences after PR #100, on 2026-11-17. The observations below describe the pre-follow-up source. PR #104 subsequently implemented the main readability, icon-label and disclosure work; see Implementation status below. This audit is not a claim of visual testing. The owner requested no additional screenshots for this iteration.

## Typography

The main Preferences view now uses semantic callout text for most explanations. The remaining inconsistency is in child panes and the main queue.

| Location | Current source | Recommendation |
| --- | --- | --- |
| Main queue, `FileRowView` in `ContentView.swift` | Failure messages, fallback notices and progress use caption text; completed-job timing uses fixed 10-point text with tertiary contrast | Promote actionable status/errors to body or callout with sufficient contrast. Keep exact timings in an optional details area using readable monospaced text. |
| Sidebar in `ContentView.swift` | Configuration/statistics headings use caption2; most navigation/configuration text is fixed at 14 points | Use consistent semantic styles; keep selected model and collection readable without enlarging every decorative icon. |
| `CPUEmbeddingSettingsPane.swift` and `EmbeddingCacheSettingsPane.swift` | Several descriptions and readiness messages remain captions | Align explanatory text with Preferences callout styling; keep compatibility warnings prominent. |
| `LocalQdrantPane.swift` | Resource explanations, configuration paths and diagnostics use captions | Increase explanatory and diagnostic text consistently; allow long paths and errors to wrap or be selected. |

Preferences currently uses a fixed 660 × 760 frame, and the sidebar has a 180–240 width range. Check those constraints on the MacBook before increasing typography.

Prefer a shared semantic typography policy over scattered hardcoded sizes. Increasing all fonts uniformly can break the narrow sidebar and dense queue rows. Validate long filenames, long errors, narrow windows, light/dark appearance and keyboard navigation when implementing. A separate app-wide text-size setting would need a broader layout/accessibility pass; it is not the first change to make.

## Icons

The sidebar, Preferences tabs, file rows and connection status already have icons. Adding more everywhere would increase noise.

Useful additions are text-plus-SF-Symbol labels on Simple setup links: Documents (`doc.text`), Database (`externaldrive`), Embeddings (`cpu`), Chat (`bubble.left.and.bubble.right`) and Help (`questionmark.circle`). Keep the visible words; icons supplement meaning rather than replace it.

The queue's icon-only remove button needs an explicit accessible action name with filename context and help text such as “Remove from queue.” Make clear that this removes the job, not the source file. Status should always combine text with shape/icon as well as color. Do not turn configuration icons green merely because an endpoint is saved.

## Collapsible sections

Use native disclosure groups for optional details, not nested submenus for ordinary settings. Suggested candidates:

- Document metadata fields, with a summary such as “N fields included,” and processing/chunking tuning with current values.
- Advanced embedding performance: batching, concurrency and cache options.
- Advanced Qdrant upload tuning: batch size, timeout, distance, quantization and hybrid options, with a summary of current values.
- Colima configuration paths and resource details, leaving service state and Start/Stop actions visible.
- Completed-job timing and cache diagnostics, leaving the result summary visible.
- Simple mode's More options links, if the setup page remains too tall after the typography change.

Keep the output choice, destination, current provider/model/collection, compatibility warnings, failures, active progress and cancellation controls visible. A collapsed section should summarize any active nondefault configuration rather than conceal it. Do not collapse the entire sidebar navigation or add another disclosure layer around an already small Simple page by default.

Disclosure state must affect presentation only. Collapsing must not reset settings, dismiss unsaved field drafts, cancel checks/downloads or stop a Colima operation. LocalQdrantPane currently cancels its task on disappearance, so wrapping it in conditional removal would change behavior. Keep operation ownership alive and test collapse/expand during work before adopting that pattern.

## Priorities and references

First align small queue and nested-pane text, then improve icon-only accessibility and selected setup-link labels. Introduce disclosure only for long optional technical sections. Preserve the existing Simple/Advanced switch and saved configuration.

The preceding research used official project documentation and repositories, not running-app comparisons:

- [CotEditor](https://github.com/coteditor/CotEditor): native Swift/Cocoa interaction and separate personal-build instructions; [its website](https://coteditor.com/) emphasizes familiar settings and immediate access to the primary task.
- [IINA](https://iina.io/): familiar macOS controls and customizable sidebars support keeping the main workflow focused.
- [Stats](https://github.com/exelban/stats): visible status and optional modules illustrate task-relevant information; its troubleshooting documents concrete next actions.

For personal installation and current update limitations, see [personal installation](personal-installation.md). Runtime maintenance and safe app replacement are tracked separately as [PER-240](https://linear.app/hansdoebel/issue/PER-240) and [PER-241](https://linear.app/hansdoebel/issue/PER-241).

## Implementation status after the audit

[PR #104](https://github.com/hansdoebel/chunky/pull/104) shipped readable queue/status and nested Preferences text, accessible queue removal, text-plus-symbol setup links, flexible Preferences sizing, consistent wider sidebar bounds, settings search, and selective disclosure groups with current-value summaries. System/Light/Dark appearance is saved across native windows. The fixed-size and caption observations above are historical, not a description of the current implementation. Current behavior is documented in [interface modes](interface-modes.md).

The remaining optional ideas include disclosure for completed-job diagnostics and additional document-processing tuning. They have not been implemented merely because they appear in this audit. Screenshot validation was waived by the owner; native builds, regression tests and independent reviews passed for the shipped changes.
