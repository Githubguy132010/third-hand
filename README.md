# Third Hand

A macOS 14+ menu-bar assistant. Focus an app, press **Control–Space**, and describe what you want done. Press the shortcut again or the status panel's × to cancel.

## Build and run

```sh
swift test
bash Scripts/build.sh --install
open "Third Hand.app"
```

Grant **Accessibility** permission in System Settings → Privacy & Security. For custom interfaces such as Blender, also grant **Screen Recording** (called Screen & System Audio Recording on newer macOS versions), then relaunch. The build script uses a pinned Apple signing identity and installs updates at the repository’s `Third Hand.app` path. The one-time transition from old ad-hoc builds requires reauthorizing the app; subsequent builds retain the same designated requirement.

Use **Set API Key…** in the menu bar to enter an **OpenRouter** key. Keys are saved in macOS Keychain; the previous `~/.thirdhand-api-key` file is migrated and removed only after a successful Keychain write. TypeSafe-only keys are not supported by the new client.

Accessible controls use `typesafe/jev-1.13` for action selection. The default text/vision model is `google/gemini-2.5-flash-lite`; it generates field contents only after Jev selects TYPE_TEXT, and plans visual actions when accessibility cannot expose suitable controls. Both use the same OpenRouter key. OpenRouter lists $0.10 per million input tokens and $0.40 per million output tokens as of this audit; screenshots also consume input tokens. Pricing: https://openrouter.ai/google/gemini-2.5-flash-lite/pricing

To override the model when launching from a terminal:

```sh
THIRDHAND_MODEL=google/gemini-2.5-flash-lite "Third Hand.app/Contents/MacOS/ThirdHand"
```

Use an image-capable model supporting structured JSON-schema output when Screen Recording is enabled. The app sends the goal, current window accessibility text, and recent actions to OpenRouter. For custom interfaces or a blocked/failed accessibility path, it sends a JPEG of the target window each visual step. Granting Screen Recording alone does not enable screenshots on the accessibility path. It does not capture the full desktop. Request contents, generated text, screenshots, and API keys are not logged.

## How control works

Each step observes the current window, requests one validated action, performs it, and observes again. Jev selects only compatible enabled targets. Text generation is a separate field-specific request. Visual/fallback chat requests use a strict JSON schema with observed target IDs. Invalid decisions receive up to two correction retries before stopping; no invalid action is executed. Accessibility click actions are preferred, with real mouse clicks as fallback. Text uses Unicode keyboard events so web/custom controls receive input events; verified accessibility writes cover fields without clickable geometry. Search submission and shortcuts such as Blender's F3 operator search use keyboard actions. The selector does not generate text. TYPE_TEXT invokes the field-text helper automatically, never a request to re-enter text.

The runner attempts to enable Chromium accessibility. Sparse accessibility trees or a blocked accessibility-only step trigger screenshot mode. If screen access is unavailable, it explains the required macOS setting. Switching apps stops execution; moving or replacing the window while the model responds discards that response. Runs stop after 30 steps or repeated identical actions without accessibility-state progress.

## Audit and changes

| Original issue | Change |
| --- | --- |
| Only 15 guessed words/phrases could be selected for text; missing values opened another prompt | Standard OpenRouter chat completion generates the complete text in context; removed the input-prompt callback |
| Empty accessibility tree immediately rejected Spotify/custom UI | Chromium accessibility opt-in, deeper bounded traversal, target-window screenshots |
| Clicks and text writes ignored AX errors | Check action results and use coordinate clicks / keyboard entry as fallback; failures are fed into the next decision |
| No keyboard actions to submit a search or invoke an operator | Validated keys and modifier combinations, double-click and right-click |
| Window reference never refreshed | Re-read focused window and global window bounds every step |
| Only interactive elements were visible to the model | Include static text and numeric state so the model can inspect results |
| Cancellation left network work and late UI updates alive | Cancel the task and ignore callbacks from obsolete runners |
| “Keychain” actually meant a plaintext home-directory file | Real Security framework Keychain storage with migration |
| Errors replaced the user's clipboard | Display errors in the status panel; input also avoids the clipboard |
| Request/response logs exposed task contents | Removed payload logging |

## Validation and remaining work

Automated tests cover full text preservation, malformed responses, invalid/disabled targets, missing text, keyboard validation, coordinate validation and multi-monitor mapping, plus an intercepted OpenRouter request/response. They do not call paid APIs or control real apps.

Live Spotify/Blender compatibility has **not** been verified. Suggested manual checks after building:

- Spotify: “Search for Boards of Canada” — verify the entire phrase is entered and submitted without another text prompt.
- Blender, in a disposable scene: “Add a UV sphere” — verify operator search, generated text, and result observation.
- Cancel during “Thinking…” and switch apps during a request — verify no later input is sent.
- Move the target window during a request — verify it is observed again before a coordinate action.
- Deny Screen Recording — verify an actionable error for sparse/custom UI.

Dragging, held mouse gestures, direct slider values, and application-specific Blender scripting are not implemented. Tiny controls and complex 3D workflows remain difficult for a low-cost vision model. The loop detector currently compares accessibility state rather than image changes, so repeated legitimate visual-only actions may stop early. Input submission is followed by model observation, not guaranteed semantic verification. macOS permission prompts must be completed by the user. Broader app integration tests, image-based progress detection, and configurable stronger-model fallback are the next useful improvements.

## Reference architecture

[jev-ultrafast](https://github.com/browser-use/jev-ultrafast) separates indexed action/target selection from a small field-text generator. Useful next improvements are an accessibility-based constrained selector, text generation only after selecting the field, target-level freshness checks, and state-driven waits. Its DOM execution and no-coordinate guarantees cannot be directly transferred to Blender's custom interface; Third Hand still needs a separate visual path. The current implementation uses Jev on the accessibility path, a separate small text helper, and an image-capable planner for visual fallback.

## Stable signing and updates

Run `bash Scripts/build.sh --install` for local updates, then open the repository-root `Third Hand.app`. The script pins an available Developer ID Application certificate (or Apple Development when no Developer ID exists) in the ignored `.thirdhand-signing-identity` file. It fails if that certificate is unavailable, verifies each new build against the installed app's designated requirement, and preserves the previous app under `.build/install.*` before replacement. Do not delete the identity file, switch certificate types, use ad-hoc signing, or launch old Desktop/build-folder copies as part of routine updates.

The previous `codesign --sign -` workflow identified each build by its changing code hash. The certificate-signed workflow identifies the app by its bundle ID and signing identity instead. A modified test app was re-signed and verified against the original requirement; both requirements matched. This validates identity continuity, not an end-to-end TCC permission migration. macOS must approve the transition from the old ad-hoc identity once; Screen Recording or Keychain may also request that initial approval.

## Latency

Screen capture is no longer triggered merely by permission being enabled. Jev selects actions and matching targets in one request, and text generation runs only for TYPE_TEXT. A failed Jev request switches that run to the text-only chat planner instead of repeatedly calling a failed endpoint. Blocked, failed, or repeated accessibility actions enable visual fallback. Custom interfaces with no usable controls go directly to vision.

AX metadata is read in batches with a shorter scan budget. The former fixed 650 ms sleep is replaced by observing for a state change in short intervals, reusing that observation for the next step; an individual AX scan can outlast the nominal 300 ms polling window. Visual actions retain a 100 ms redraw allowance and explicit WAIT actions retain their loading wait. Logs record observation, Jev, field-text, and planner milliseconds without request contents. Live task speedups have not yet been benchmarked.
