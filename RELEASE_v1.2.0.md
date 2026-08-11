# FrostSeek Aura Tracker v1.2.0

Combat role inference update for Manastorm raid monitoring.

## New

- Tracks effective healing done to current raid members.
- Tracks hostile and environmental damage taken by current raid members.
- Infers up to three likely Healers and two likely Tanks.
- Requires sustained evidence and a meaningful share of raid activity.
- Decays old evidence automatically between pulls.
- Shows inferred role names in the compact overlay.
- Adds `/fsaura roles` for confidence-labelled results.
- Adds `/fsaura rolesreset` to clear accumulated evidence.

## Important limitations

Combat roles are advisory. Encounter mechanics, absorbs, off-healing, pets,
unusual builds, and incomplete combat-log range can influence the result.

This feature does not change Aura-provider assignments. Aura coverage can be
verified at subgroup level, but the game API still may not reveal which player
owns an active Aura.

## Required dependency

[FrostSeek 2.2.5 or newer](https://github.com/ayro-CMD/FrostSeek)
