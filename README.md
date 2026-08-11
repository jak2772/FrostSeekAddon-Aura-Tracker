# FrostSeek Aura Tracker

**Manastorm Aura of Experience raid management for Project Ascension**

FrostSeek Aura Tracker is a companion addon for **FrostSeek 2.2.5** designed for managing **Aura of Experience** coverage in 15-player Manastorm leveling raids on Project Ascension.

It adds a dedicated **Auras** tab directly into FrostSeek and provides subgroup coverage tracking, provider management, recruitment handling, candidate parsing, alerts, replacement warnings, and a compact in-game overlay.

## Current release

**v1.1.4**

Target environment:

- Project Ascension
- Darkmoon / Season 10 Wildcard
- WoW 3.3.5 client
- Interface `30300`
- FrostSeek `2.2.5`
- Locale tested: `enUS`

## Required dependency

- [FrostSeek 2.2.5 or newer](https://github.com/ayro-CMD/FrostSeek)
- Project Ascension compatible WoW 3.3.5 client

FrostSeek is mandatory: WoW loads it before Aura Tracker, and v1.1.4 verifies
that the loaded version is at least 2.2.5 before adding the Auras tab.

This is a **companion addon**. It does not modify or redistribute FrostSeek source.

## Installation

Extract the addon folder into:

```text
World of Warcraft/
`-- Interface/
    `-- AddOns/
        |-- FrostSeek/
        `-- FrostSeek_AuraTracker/
```

The addon folder should contain:

```text
FrostSeek_AuraTracker/
|-- FrostSeek_AuraTracker.lua
|-- FrostSeek_AuraTracker.toc
`-- README.txt
```

Then restart the client or run:

```text
/reload
```

After loading, FrostSeek should contain a new **Auras** tab.

Expected startup messages:

```text
[FrostSeek Aura] Loaded Aura Tracker v1.1.4
[FrostSeek Aura] Commands ready: /fsaura and /fsa
```

## Core model

Manastorm leveling raids are managed as:

```text
15-player raid
3 raid subgroups
5 players per subgroup
1 Aura of Experience provider per subgroup
```

Desired state:

```text
P1  provider
P2  provider
P3  provider
```

## Aura state model

The addon distinguishes between different levels of certainty instead of collapsing everything into one green/red state.

### Confirmed provider

A player has been positively identified as an Aura provider.

```text
Sonoftyrion  CONFIRMED PROVIDER
```

### Manual provider

A player was explicitly assigned by the user.

```text
Mimir  MANUAL PROVIDER
```

### Aura active, provider unknown

The subgroup is definitely receiving Aura of Experience, but provider identity could not be resolved safely.

```text
AURA ACTIVE  PROVIDER UNKNOWN
```

### Unknown / out of range

The subgroup cannot currently be queried reliably.

```text
UNKNOWN / OUT OF RANGE
```

This is intentionally not treated as the same thing as confirmed Aura loss.

### No Aura

The subgroup is locally queryable and no Aura of Experience is detected.

```text
NO AURA
```

## Project Ascension Aura limitation

Project Ascension exposes Aura of Experience state in an unusual way.

The addon uses:

```lua
C_Aura.UnitHasAura(unit, 818059)
```

to determine whether a unit is **receiving Aura of Experience**.

This does not reliably identify which player owns or provides the Aura.

Automatic verification is also primarily local-range data.

For that reason:

- **outside Manastorm:** Aura verification is treated as local-range information
- **inside Manastorm:** local subgroup Aura state is treated as authoritative because the raid is expected to be together

The addon avoids guessing provider identity unless it has enough evidence.

## Manastorm-aware mode

When entering Manastorm, the addon waits approximately **2.5 seconds** for roster and Aura state to settle, then performs an automatic audit.

Example:

```text
Manastorm check: P1 OK  P2 OK  P3 MISSING - need Aura for P3.
```

## Raid-ready indicator

The main UI and overlay provide compact status:

```text
Auras: 3/3 READY
Auras: 2/3 NOT READY
Auras: 1/3 UNKNOWN
```

## Provider inference

Because Ascension does not expose owner identity consistently, the addon can infer a provider from a safe subgroup transition:

```text
P3: NO AURA
    ↓
exactly one player joins or moves into P3
    ↓
P3: ACTIVE
    ↓
newcomer can be confirmed as Aura provider
```

Multiple simultaneous arrivals do not trigger provider inference.

## Duplicate provider detection

The addon detects distribution mistakes such as:

```text
P1: 2 Aura providers
P2: 1 Aura provider
P3: 0 Aura providers
```

and reports the reason instead of only saying "incorrect distribution".

Example:

```text
P1 duplicate providers (2); P3 missing provider.
```

## Move suggestions

When enough provider identity is known, the addon can suggest a minimal correction:

```text
Suggestion: move Statstick from P1 -> P3.
```

It does not automatically move raid members.

## Recruitment

Recruitment messages adapt to the actual missing parties.

Examples:

```text
LFM Manastorm Leveling 11/15 - need Aura for P2 + P3 (2 players). Whisper "aura" for invite.
```

```text
LFM Manastorm Leveling 14/15 - need 1 Aura of Experience player for P3. Whisper "aura" for invite.
```

Controls include:

- Advertise Now
- Start Repeat
- Stop
- Scan Raid
- configurable channel slot
- configurable repeat interval
- periodic safety scan

## Recruitment reply parsing

Only an exact, case-insensitive, whitespace-trimmed:

```text
aura
```

qualifies as an Aura candidate.

These qualify:

```text
aura
AURA
 aura
aura 
```

These do not:

```text
I have aura
aura pls
inv aura
yes
dps no aura
```

Non-exact replies are kept separately under **Non-aura candidates**.

Auto-invite can only trigger for an exact Aura candidate.

## Candidate management

Candidate lists are independently scrollable.

Candidate rows show:

- player name
- actual whisper text
- status
- Invite
- Mark

Tracked statuses include:

- New
- Invited
- Declined
- Already grouped
- Offline
- Aura confirmed

Candidates are keyed by character name, so repeat whispers update the existing row rather than creating duplicates.

Candidates expire after approximately **10 minutes**.

Once a candidate joins the raid, they are removed from recruitment lists and represented by the live roster instead.

## Provider join / leave alerts

Known, manual, and confirmed Aura providers can generate roster-driven alerts.

Examples:

```text
Aura player Statstick joined the raid in P3.
```

```text
Aura player Statstick left. P3 now needs an Aura player.
```

Provider departure remembers the last subgroup long enough to produce a useful alert.

## Level 59 replacement warning

When a tracked Aura provider reaches **level 59**, the addon emits a one-time replacement warning.

Example:

```text
Aura player Statstick in P3 has reached level 59 and is about to hit max level. Prepare a replacement Aura player.
```

The main party row is flagged:

```text
Statstick [59 - REPLACE SOON]
```

The overlay also shows:

```text
Statstick is 59 - replace soon
```

The warning is transition-based and is not repeated by periodic scans.

## Alerts

Available alert options:

- Send alerts to raid / party chat
- Leader / assistant broadcasts only
- Sound on provider loss
- Aura player leaves
- Aura player joins
- Incorrect distribution
- 3/3 restored
- Level 59 replacement warning

## Alert debouncing and anti-spam

Distribution changes are debounced by roughly **1.5 seconds** before being announced.

Periodic safety scans do not resend the same state.

Identical alert text within a short interval is suppressed as an additional guard.

## Overlay

The addon provides a compact floating overlay showing:

```text
Manastorm Auras
Auras 3/3 READY

P1  Sonoftyrion  confirmed
P2  Mimir        manual
P3  Statstick    confirmed

Raid ready
```

The overlay can be:

- shown / hidden
- moved
- locked
- scaled from 55% to 200%

Position and scale are stored separately to avoid frame-scaling drift.

## Slash commands

Main command:

```text
/fsaura
```

Alias:

```text
/fsa
```

Useful commands:

```text
/fsaura
/fsaura scan
/fsaura sensors
/fsaura overlay
/fsaura mark <player>
/fsaura unmark <player>
/fsaura forget <player>
/fsaura forget
/fsaura recruit
```

## Updating

For an existing installation:

1. Delete or replace the existing `Interface/AddOns/FrostSeek_AuraTracker` folder.
2. Extract the new version.
3. Run:

```text
/reload
```

Deleting the old addon folder first is recommended when moving between major builds so stale Lua files are not retained.

## Troubleshooting

### Auras tab does not appear

Confirm FrostSeek is loaded:

```text
FrostSeek: v2.2.5 -- All modules loaded
```

and look for:

```text
[FrostSeek Aura] Integrated into FrostSeek as the Auras tab.
```

### `/fsaura` does not work

Look for:

```text
[FrostSeek Aura] Commands ready: /fsaura and /fsa
```

If this does not appear, check for a Lua load error.

### Aura state is UNKNOWN outside Manastorm

This can be expected. Automatic Aura verification depends on locally available data.

Move closer to the relevant players or verify again inside Manastorm.

### Player is receiving Aura but not identified as provider

This can also be expected.

Ascension may expose that a unit is receiving Aura without exposing who owns it. The addon deliberately avoids inventing provider identity.

Use manual assignment when needed.

## Repository layout

```text
FrostSeek_AuraTracker/
|-- FrostSeek_AuraTracker.lua
|-- FrostSeek_AuraTracker.toc
`-- README.txt

dist/
`-- FrostSeek_AuraTracker-v1.1.4.zip

README.md
CHANGELOG.md
LICENSE
RELEASE_v1.1.4.md
.gitignore
publish-release.ps1
```

## License

This repository contains FrostSeek Aura Tracker only.

[FrostSeek](https://github.com/ayro-CMD/FrostSeek) itself is a separate,
required addon and is not redistributed here.

See `LICENSE` for the companion addon's license.
