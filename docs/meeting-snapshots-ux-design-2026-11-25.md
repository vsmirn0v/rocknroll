# In-Meeting Visual Snapshots ("Snap to Summary") — iOS & macOS Design Draft

Date: 25 November 2026. Status: UX design updated with confirmed settings & multi-meeting performance guardrails.

Extend **Rock’n’Roll for iOS** and **NativeMacGuest (macOS)** so users can capture clean, native-resolution snapshots of a **specific screen share**, a **specific participant or local camera**, or the **full meeting stage** during an active meeting, and have those snapshots automatically anchored into the **Meeting Summary**, **Transcript timeline**, **Live Notes**, and **Obsidian / Markdown exports**.

Companion interactive draft: [meeting-snapshots-ux-draft.html](../design/meeting-snapshots-ux-draft.html).

---

## 1. Design Principles

1. **Raw stream buffer over OS pixels**: Use `CompanionVideoSink.snapshotImage(expectedCrop:)` (`NativeMacGuest/VideoTile.swift`) on macOS and `CallVideoView.snapshotFrame()` (`RockNRoll/CallVideoView.swift`) on iOS to materialize full-resolution decoded frames off-main—free of speaker chips, floating toolbars, notifications, and outside OS windows.
2. **Zero-modal default + 6-second retroactive forgiveness**: Single tap / `⌘⇧S` captures immediately (`<150ms`) using smart priority (`Focused Screen Share` → `Focused/Pinned Camera` → `Full Meeting Stage`). A 6-second transient in-memory buffer of sibling streams lets users flip the already-captured snapshot inside the toast (`Screen · Alex` ⇄ `Camera · Maya` ⇄ `Full Stage`) without repeating the shot.
3. **Never interrupt audio or note-taking**: Capturing never changes microphone/camera state, never steals keyboard focus from `MeetingNotesView` / `IOSInCallNotesView`, and never broadcasts room notifications.
4. **Local-first durability**: Snapshots belong to the `sessionID` record on-device independently of AI outcome generation, syncing via `RoomSyncCoordinator` / `MacWorkspaceSyncCoordinator` and exporting cleanly to Markdown / Obsidian.

---

## 2. Draft A: macOS Capture Chrome (`NativeMacGuest`)

```text
Q4 Architecture Sync · 14:22 · Live                     [My Notes] [Mini]
┌───────────────────────────────────────────────────┬─────────────────────┐
│ (AK) Alex Kim is speaking                         │ 4 participants      │
│                                                   │ ┌─────────────────┐ │
│   [Edge Gateway (TTL 30s) ──▶ LiveKit Media]      │ │ Presenting [📷] │ │
│                                                   │ │ Alex Kim (Cam)  │ │
│                                                   │ └─────────────────┘ │
│                                                   │ ┌─────────────────┐ │
│  [Alex is presenting]   [📷 Snap | ▾] [⌗ Text][Fit]│ │ Whiteboard [📷] │ │
│                                                   │ │ Maya Lin (Cam)  │ │
│                                                   │ └─────────────────┘ │
│  ┌─ Floating Pill (4.5s, no focus steal) ───────┐ │ [⊞ Full Stage]    │
│  │ [thumb] ✓ Attached · 14:22 · [Screen · Alex▾]│ │                   │
│  │  [+ Add note…]        [+ Notes]  [Undo ⌘Z]   │ │                   │
│  └──────────────────────────────────────────────┘ │                   │
└───────────────────────────────────────────────────┴─────────────────────┘
  🎤 Mic    📹 Cam    [📷 Snap (⌘⇧S)] [Snap Stage (⌘⇧E)]    View ▾   Leave
```

### Entry Points on macOS
- **Floating Share HUD** (`NativeDesktopZoomVideo`): `[ 📷 Snap | ▾ ]` placed directly beside `text.viewfinder` (Live Text).
- **Direct Tile Hover & Context Menu**: Hovering any tile in Gallery, Stage, or the `200pt` `SpeakerRail` (`presenterTile` / `participantTile`) reveals a top-right `camera.viewfinder` quick-snap badge; secondary click offers `Snap screen share`, `Snap camera`, `Snap full meeting`.
- **Footer & Mini-Meeting `NSPanel`**: Quick `camera.viewfinder` button on the `54pt` footer and inside `NativeDesktopMiniMeeting` so users writing notes in other apps can snap with one click or `⌘⇧S` / `⌘⇧E` / `⌘⇧1…9`.

---

## 3. Draft B: iOS Liquid Glass Capture (`RockNRoll`)

```text
┌─────────────────────────────────────┐
│     [==== Dynamic Island ====]      │
│ ┌─────────────────────────────────┐ │  ← Optional 4s banner on Side+VolUp:
│ │ System screenshot? Attach HD:   │ │    UIApplication.userDidTakeScreenshot
│ │ [Shared Screen]   [Full Stage]  │ │
│ └─────────────────────────────────┘ │
│ ┌─────────────────────────────────┐ │
│ │ Q4 Architecture Sync  [Focus ▾] │ │  ← MeetingChromeSurface (iOS 26 Glass)
│ └─────────────────────────────────┘ │
│ ┌─────────────────────────────────┐ │
│ │ Alex · Screen              [📷] │ │  ← 2-finger double-tap snaps stream
│ │   Edge Gateway (TTL = 30s)      │ │
│ └─────────────────────────────────┘ │
│ ┌───────────────┐ ┌───────────────┐ │
│ │ Maya · Cam 📷 │ │ Alex · Cam 📷 │ │
│ └───────────────┘ └───────────────┘ │
│ ┌─────────────────────────────────┐ │
│ │ [thumb] Saved · [Screen ▾] Undo │ │
│ └─────────────────────────────────┘ │
│ ┌─────────────────────────────────┐ │
│ │  (🎤)   (📹)   [📷 Snap]  (▾) (✕)│ │  ← 44×44pt AlignedCallButton dock
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

### Entry Points on iOS
- **Dock Snap Button** (`MeetingChromeContainer` / `AlignedCallButton`): Single tap = Smart Snap + `.rigid` haptic; Touch & Hold (`0.45s`, matching `MeetingActionsShortcut`) = **Live Visual Scope Sheet** showing real-time mini previews of Screen Share(s), Participant Cameras, and Full Stage.
- **Direct Tile Gesture (`CallTileContainer`)**: Two-finger double-tap or tile context menu snaps that specific stream.
- **Hardware Screenshot Bridge (ON by default, configurable in Settings)**: `UIApplication.userDidTakeScreenshotNotification` offers a 4-second Liquid Glass pill to attach the clean HD stream frame to the Meeting Summary, with an opt-out toggle in Settings.

---

## 4. Draft C: Summary, Live Text OCR & Obsidian Export

```text
Outcome (Mac AssistantOutcomeViews / iOS IOSMeetingDetailView)
┌─────────────────────────────────────────────────────────────────────────┐
│ Visual Highlights (3)                                                   │
│ ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐          │
│ │ ▭ Screen · 14:22 │ │ 📷 Camera · 14:24│ │ ⊞ Stage · 14:28  │          │
│ │ TTL = 30s        │ │ Whiteboard Path  │ │ Full Team Sign   │          │
│ └──────────────────┘ └──────────────────┘ └──────────────────┘          │
├─────────────────────────────────────────────────────────────────────────┤
│ Summary                                                                 │
│ Team aligned on Edge Gateway auth cache TTL 30s before Friday beta.     │
│                                                                         │
│ Decisions                                                               │
│ ✓ Cap auth cache TTL at 30s          [🖼 14:22 · Screen (Alex)]         │
│ ✓ Use Region-B warm standby path     [🖼 14:24 · Camera (Maya)]         │
└─────────────────────────────────────────────────────────────────────────┘
```

- **Live Text Lightbox**: Clicking any filmstrip card or evidence chip opens an inspector powered by `SharedTextRecognizer` / `VisionKit` (`ImageAnalysisOverlayView`) so code, URLs, and numbers inside snapshots are selectable/copyable, with `Jump to Transcript (14:22)`.
- **Multimodal & Local OCR Synthesis**: `SharedTextRecognizer` extracts slide/whiteboard text locally so `MeetingOutcomePrompt` enriches summaries even on text-only local models; multimodal models receive image attachments directly.
- **Obsidian Export** (`ROCKNROLL_NOTES_OBSIDIAN_SPEC.md`): Writes image attachments (`.jpg` default, `.png`, or `.png` + `.heic` per user setting) to `<Vault>/<Attachments>/` and updates a managed `### Visual Snapshots` block without overwriting manual user edits or inline `![[...]]` embeds.

---

## 5. Settings Specification (iOS & macOS)

Add a **Snapshots** section in Settings (synced preferences where applicable, with platform-appropriate controls):

| Setting | Default | Options / Behavior |
| :--- | :--- | :--- |
| **Snapshot Image Format** | **JPEG** | `JPEG` (Default, compact & universal) · `PNG` (Lossless) · `Mixed (PNG Screen + HEIC Camera/Stage)` |
| **Clean Frame on System Screenshot** *(iOS)* | **ON** | Shows the 4s Liquid Glass clean-frame attachment pill on `Side + Volume Up` (`userDidTakeScreenshotNotification`); users can toggle OFF anytime. |

---

## 6. Multi-Meeting CPU, RAM & Energy Budget

To ensure zero measurable overhead even when multiple parallel meetings are connected in `NativeDesktopWorkspace`:
1. **Zero idle/background work**: No continuous frame polling or background buffering runs during meetings. Cost is strictly **0%** until the user triggers a snap.
2. **Single visible meeting scope**: Capture operates exclusively on the visible meeting targeted by the user. Hidden, `.audioOnly`, or `.infoCard` parallel meetings are never accessed or woken up.
3. **Pool-safe transient retention**: Only the primary target encodes immediately off-main (`.userInitiated` QoS). Visible sibling streams (capped at max 3–4) detach a single copy into one transient 6-second slot so WebRTC/CoreVideo `CVPixelBuffer` pools are never pinned.
4. **Lazy Full-Stage compositing**: Stage compositing only executes if `Full Stage` is chosen initially or flipped to within 6 seconds.
5. **Deterministic auto-purge**: Any new snap replaces the previous slot; unselected frames purge after **6 seconds**, on toast dismissal, on meeting exit, or immediately upon system memory pressure (`didReceiveMemoryWarningNotification` / `DispatchSourceMemoryPressure`).

---

## 7. Edge-Case & State Matrix

| State / Condition | Behavior |
| :--- | :--- |
| **Multiple Simultaneous Shares** | Smart Snap picks focused share; Scope Picker (`▾` / `0.45s` hold) lists all shares with live thumbnails. |
| **Multiple Connected Meetings** | Capture & 6s buffer run exclusively on the single visible meeting being snapped; background connected meetings incur zero CPU/RAM/energy cost. |
| **Camera Off Mid-Click** | Uses `500ms` last-prepared-frame grace buffer; otherwise disables camera option with `"Camera is off"`. |
| **Audio-Only Mode** | Explains video decoding is paused and offers a one-tap single keyframe fetch without leaving Audio Only. |
| **Reduce Transparency / Motion** | `MeetingChromeSurface` renders solid high-contrast surfaces; rim flash switches to a static border + VoiceOver announcement. |
| **Summary Pending / Failed / Offline** | Snapshots persist locally on `sessionID` and remain viewable/searchable/exportable in Notes and Obsidian. |
