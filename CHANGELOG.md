# Changelog

All notable changes to FrostSeek Aura Tracker are documented here.

## [1.3.1] - 2026-08-11

### Fixed
- Rebuilt and republished the distributable ZIP after the v1.3.0 release asset was truncated during upload.
- No gameplay logic changes from v1.3.0.

## [1.3.0] - 2026-08-11

### Added
- Conversational recruitment parsing for applicant role, Aura availability, and level.
- Optional, deduplicated follow-up whispers with configurable message templates.
- Richer candidate rows, reply history details, and an auto-follow-up UI toggle.
- Recent raid/party chat capture through `/fsaura chat` and group sending through `/fsaura say`.

### Fixed
- Replaced the contradictory `Incorrect Aura distribution: Aura distribution healthy` report.
- When every subgroup reports an Aura, chat now says so and identifies any subgroup whose provider is unknown.
- Kept exact `aura` as the only automatic invitation trigger.

## [1.2.1] - 2026-08-11

### Fixed
- Increased the Manastorm entry Aura-settle delay from 2.5 to 5 seconds.
- Suppressed distribution and provider roster announcements during entry loading.
- Prevented the settled entry audit from scheduling a second distribution alert.
- Clears stale pending Aura alerts when entering or leaving Manastorm.

## [1.2.0] - 2026-08-11

### Added
- Combat-log role evidence for current raid members.
- Conservative Healer inference from sustained effective healing.
- Conservative Tank inference from sustained hostile/environmental damage taken.
- Decaying evidence, confidence labels, and caps of two Tanks and three Healers.
- Compact combat-role summary in the overlay.
- `/fsaura roles` and `/fsaura rolesreset` commands.

### Important
- Combat roles are advisory and remain separate from Aura-provider assignments.
- Aura coverage sensing still cannot directly identify an unknown provider.

## [1.1.4] - 2026-08-11

### Added
- Declared FrostSeek as a mandatory dependency and documented the official repository.
- Added a runtime minimum-version check for FrostSeek 2.2.5.
- Added TOC metadata for the required FrostSeek version and repository.

### Changed
- Reorganized the README so requirements and installation are easier to scan.
- Replaced corrupted directory-tree glyphs with portable ASCII formatting.

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
