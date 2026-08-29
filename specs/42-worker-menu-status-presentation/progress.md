# Worker Menu Status Presentation Progress Log

### 2026-08-29 - Task 1 complete: every status carries one dot

- The dot's colour never enters the Core target. `StatusIndicator` names the kind of state and `StatusIndicatorImage` alone maps a kind to a colour, which is what lets the grouping be unit-tested while the palette stays presentation. The grouping is the part worth a test: that a refused connection and a dropped one are the same kind of problem is a product rule, and that the healthy dot is exactly this green is not.
- The mapping is an exhaustive switch with no `default`, so an eighth `WorkerStatus` cannot compile until someone decides which kind it is. A status line with no dot is therefore unreachable rather than merely untested.
- The guard against a new state slipping through needed care. `WorkerStatus` is not `CaseIterable` and this task did not widen its public API to make it so, so a list plus a count assertion could not catch a new case. The test file restates the mapping as its own exhaustive switch instead: adding a state stops the test target compiling, which is the strongest guard available without changing the shipped API.
- `StatusIndicator` did gain `CaseIterable`, which the task did not ask for. It buys one test that no indicator kind is unreachable. Recorded because it is public API added on the sub-agent's judgement and is easy to drop if the surface should stay minimal.
- Two rendering decisions worth keeping. The image is built with a drawing handler rather than a baked bitmap, so the dynamic system colours resolve under the menu's current appearance instead of freezing a light-mode colour into a dark menu. It is explicitly not a template image, because AppKit re-tints those to one colour, which would erase the only thing the dot carries.
- Contrast is not left to hue alone: green is lightened and red darkened in HSB after resolving to sRGB, putting their relative luminance roughly two to one apart, so the two read as a light dot and a dark dot to someone with a red-green deficiency. The words beside the dot remain the real answer either way.
- The image carries no accessibility description on purpose. The line already states the status in full words, so describing the dot would make VoiceOver read the state twice.
- Focused proof, confirmed on the main thread by real exit status `0` with `Executed 255 tests, with 0 failures`. `swift build` also exits `0`, which matters here because the drawing helper lives in the app target that the test suite does not cover. Runner receipt:
- Proof receipt: `Task 1` — scope `Focused` — command `swift test` — exit `0`.
- No Elixir file was touched, so no `mix` safety check applies to this task.
