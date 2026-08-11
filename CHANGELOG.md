# Changelog

All notable changes to FrostSeek Aura Tracker are documented here.

## [1.5.0-beta.3] - 2026-08-11

### Rebuilt
- Replaced the simplified v1.5 prototype with the complete Manastorm Recruiter 0.6.8 module stack.
- Embedded the upstream mission-control UI directly inside FrostSeek's Auras module.
- Included the full parser, public-chat scanner, capacity and Aura-reservation rules, applicant queue, invitation timeouts, roster editor, group optimizer, Ready Check state, Manastorm phases, rebuild recovery, minimap control, commands, settings, and twenty-field message system.

### Integrated
- FrostSeek automatic Aura provider state now feeds the complete recruiter roster, counters, UI and optimizer.
- Manual Aura edits in the recruiter synchronize back to FrostSeek provider assignments and suppressions.
- FrostSeek combat evidence supplies automatic Tank and Healer roles to the recruiter roster.
- FrostSeek remains authoritative for in-instance Aura validation and the five-second entry audit, preventing duplicate Aura warnings.
- Disabled the legacy Aura-only whisper/recruitment loop while the full recruiter is active, preventing duplicate replies and adverts.

### Licensing
- Relicensed the v1.5 derivative under GPL-3.0-or-later and added upstream attribution.

## [1.5.0-beta.2] - 2026-08-11

### Added
- Added a full two-column Messages editor for automated applicant replies and workflow announcements.
- Added editable replies for missing role, Aura, level, accepted applications, and already-inside-Manastorm responses.
- Added an immediate Auto Replies ON/OFF control inside the Messages editor.

## [1.5.0-beta.1] - 2026-08-11

### Verification build
- Adds a FrostSeek-styled, phased Manastorm recruiter workspace.
- Adds editable roster targets and persistent applicant, reservation, and rejection state.
- Adds applicant role/Aura correction plus Invite, Reserve, Release, and Reject actions.
- Adds three live raid-group cards with clickable Aura assignments.
- Adds stepwise subgroup optimization, Ready Check, roster posting, and guarded Manastorm start.
- Adds run monitoring, persistent stepwise rebuild recovery, and guarded Post & Leave.
- Adds editable recruitment, roster, level, and leave message templates.
- Adds direct minimap access to the integrated recruiter workspace.
- Replaces broken stock input templates with complete FrostSeek-styled fields.
- Constrains the Alerts panel inside FrostSeek's available tab height.
- Intended for interface and in-raid verification; v1.4.1 remains the stable release.

## [1.4.1] - 2026-08-11

### Fixed
- Replaced the incorrect Paladin fallback icon with bundled Aura of Experience artwork.
- Prevented the recruitment-reply description from overlapping the Aura candidate heading.
- Moved the inline raid-chat composer out of the alert toggles.
- Hid candidate scrollbars when their lists do not overflow.
- Hid Aura icons on empty roster slots while retaining grey clickable icons on actual players.
- Reset the editable recruitment field to its first character after automatic refreshes.

## [1.4.0] - 2026-08-11

### Added
- Three live five-player raid-group panels in the FrostSeek Auras tab.
- Aura of Experience icon on every occupied roster slot.
- Clickable bright/grey Aura assignment toggle with explicit automatic-provider suppression.
- Compact role and level indicators for every raid member.
- `Post Roster`, `Ready Check`, and advisory `Optimize` actions.
- Inline party/raid chat composer in the setup panel.

### Changed
- Replaced the former three-row coverage section with the operational raid board.
- Moved subgroup health into each group header while preserving existing sensing and provider-inference logic.

## [1.3.2] - 2026-08-11

### Added
- Editable outgoing recruitment message field with a `Use Auto` reset.

### Fixed
- Shortened the auto-invite and auto-follow-up labels to prevent overlap.
- Condensed coverage warnings so they fit the status panel.

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
