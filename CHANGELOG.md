# Changelog

All notable changes to FrostSeek Aura Tracker are documented here.

## [1.1.3] - 2026-08-11

### Fixed
- Removed unsupported Unicode status glyphs that could render as literal `?` characters in the Ascension/WotLK client.
- Replaced glyph-based state display with explicit labels such as `READY`, `NOT READY`, `CONFIRMED PROVIDER`, `UNKNOWN / OUT OF RANGE`, and `NO AURA`.
- Compacted the Recruitment Replies panel while preserving scrollbars.
- Constrained the Alerts panel inside the FrostSeek content frame.
- Repositioned the Lock Overlay control so it remains inside the FrostSeek window.

## [1.1.2] - 2026-08-11

### Fixed
- Fixed `ProviderDisplayName` declaration-order bug causing:
  `attempt to call global 'ProviderDisplayName' (a nil value)`.

## [1.1.1] - 2026-08-11

### Added
- Level 59 replacement warnings for tracked Aura providers.
- On-screen `[59 - REPLACE SOON]` state.
- Overlay replacement warning.
- Independent Level 59 warning toggle.

## [1.1.0] - 2026-08-11

### Added
- Provider confidence/state distinction.
- Party health summaries.
- Compact raid-ready indicator.
- Duplicate provider detection.
- Minimal move suggestions.
- Provider departure memory.
- Candidate aging.
- Candidate statuses.
- Candidate auto-removal after joining.
- Exact Aura-candidate promotion after successful coverage transition.
- Smarter recruitment messages.
- Sensor-aware recruitment stopping.
- Manastorm-aware mode.
- Delayed Manastorm entry audit.
- Debounced distribution alerts.
- Leader/assistant-only broadcasts.
- Optional sound alerts.
- State-change-only warning logic.
- Reason-aware warning text.
- Candidate and alert deduplication.

### Fixed
- Warning/local-range text overlap in the FrostSeek UI.

## [1.0.2] - 2026-08-11

### Changed
- Reworked Alerts panel layout.
- Moved Lock Overlay beside overlay controls.
- Rebuilt overlay scaling around a separate unscaled mover and scaled content frame.
- Improved resize grip mouse tracking.

## [1.0.1] - 2026-08-11

### Added
- Exact `"aura"` whisper parsing.
- Separate Aura and Non-aura candidate lists.
- Actual candidate message display.
- Independent candidate scrollbars.
- Local-range / Manastorm explanatory text.

### Changed
- Auto-invite now only triggers on the exact `aura` keyword.

## [1.0.0] - 2026-08-11

### Added
- First production release.
- FrostSeek Auras tab.
- P1/P2/P3 Aura provider management.
- Automatic subgroup Aura sensing.
- Manual provider fallback.
- Recruitment generation.
- Whisper candidate handling.
- Provider join/leave alerts.
- Draggable/scalable overlay.
- Safe provider inference from subgroup coverage transitions.
