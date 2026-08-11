# FrostSeek Aura Tracker v1.1.3

Production release of the FrostSeek-integrated Manastorm Aura manager for Project Ascension.

## Highlights

- Tracks Aura of Experience coverage across P1 / P2 / P3.
- Distinguishes confirmed, manual, active-unknown, out-of-range, and missing Aura states.
- Manastorm-aware verification with delayed entry audit.
- Smart recruitment messages based on actual missing parties.
- Exact `"aura"` whisper candidate parsing.
- Separate non-Aura recruitment replies.
- Candidate status tracking, aging, deduplication, and auto-removal on join.
- Automatic provider inference from subgroup coverage transitions.
- Duplicate-provider warnings and move suggestions.
- Provider join/leave alerts.
- Level 59 replacement warnings.
- Optional leader/assistant-only raid broadcasts.
- Optional sound alerts.
- Debounced state-change-only warning logic.
- Compact draggable/scalable overlay.

## v1.1.3 fixes

- Replaced unsupported Unicode status glyphs with clear text labels.
- Fixed confusing `?` characters in the Ascension client.
- Kept the Alerts panel contained inside the FrostSeek window.
- Compacted recruitment reply lists while retaining scrollbars.
- Repositioned Lock Overlay to stay inside the UI.

## Installation

1. Download `FrostSeek_AuraTracker-v1.1.3.zip`.
2. Extract `FrostSeek_AuraTracker` into:

```text
Interface\AddOns\
```

3. Ensure FrostSeek 2.2.5 is installed.
4. Restart the client or run:

```text
/reload
```

5. Open FrostSeek and select the new **Auras** tab.

## Important

Automatic Aura verification relies on locally available Project Ascension Aura data.

It is intended primarily for use inside Manastorm, where raid members are together and subgroup Aura state can be treated as authoritative.

Outside the instance, `UNKNOWN / OUT OF RANGE` is deliberately not treated as confirmed Aura loss.
