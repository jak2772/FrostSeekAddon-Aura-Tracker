# Manastorm Recruiter feature parity

Baseline: [Manastorm Recruiter 0.6.8](https://github.com/Tomatensalat91/ManastormRecruiter).

The v1.5 implementation loads the complete upstream module set. Items below
are retained unless explicitly marked as a FrostSeek extension.

## Core and persistence

- Account and character SavedVariables with migrations and defaults.
- Session applicant order, whisper history, chat-scanner history and rebuild recovery.
- Placeholder expansion, configurable message routes and message reset/migration.
- Slash commands, roster events, Manastorm events, Ready Check events and update loop.

## Recruitment and applicants

- Role, Aura and level parser with short follow-up answers.
- Missing-information questions and configurable automatic replies.
- Public-channel LFG scanner with deduplication.
- Role caps, total cap, Aura-reserved role slots and capacity replies.
- Waiting/reserve/joined/rejected/declined/left states.
- Pending invitation accounting, reminders, expiry, release and reinvite.
- Recruitment posting, automatic intervals, roster posting and session reset.

## Raid and grouping

- Editable role/Aura controls for applicants and grouped players.
- Full roster counts and unknown-role tracking.
- Desired 15-player role layout across Groups 1-3.
- Aura distribution, swap planning and partial-roster optimization.
- Stepwise protected subgroup moves with verification between actions.
- Primary Tank assignment, roster kick controls, disband and embedded raid chat.
- Ready Check start, per-member state, summaries and roster invalidation.

## Manastorm run lifecycle

- Guarded Level 1 entry and recruitment shutdown.
- Roster validation and level-59/60 monitoring.
- Configurable local, raid and raid-warning messages.
- Level-aware Post & Leave workflow.
- Persisted rebuild snapshot, resume/discard prompt and manual retry controls.
- Level-60 removal, Manastorm exit delay, eligible reinvites and recovery stages.

## Interface

- Applicants, Raid Groups and Settings workspaces.
- Full twenty-field message editor and routing controls.
- Appearance/compact controls, minimap button and automatic phase switching.
- Applicant paging, public-chat scanner, three raid group cards and rebuild panel.
- FrostSeek-native parent, lifecycle, sizing and theme colors.

## FrostSeek extensions

- Automatic Aura of Experience sensing and confirmed provider ownership.
- Manual provider assignment/suppression synchronized in both interfaces.
- Cross-party coverage state and unknown-provider reporting.
- Combat-evidence Tank and Healer inference injected into the editable roster.
- Five-second Manastorm entry grace period and settled entry audit.
- Aura loss/restoration alerts and draggable compact overlay.
- Correct bundled Bonus XP texture.
- FrostSeek owns in-instance Aura validation to prevent duplicate/conflicting warnings.

## Verification

- Upstream CoreTests: passing.
- Upstream UITests, adapted for FrostSeek hosting and texture path: passing.
- FrostSeekBridgeTests for Aura state, provenance, inferred role and manual sync: passing.
- All installed Lua files compile successfully in the verification runtime.
