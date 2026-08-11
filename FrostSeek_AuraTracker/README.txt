FrostSeek Aura Tracker v1.3.2

Requires FrostSeek 2.2.5 or newer:
https://github.com/ayro-CMD/FrostSeek

- Declares FrostSeek as a mandatory addon dependency.
- Checks the loaded FrostSeek version before integrating.
- Shows one clear warning when FrostSeek is older than 2.2.5.
- Learns likely Tanks from sustained hostile damage taken.
- Learns likely Healers from effective healing done to raid members.
- Shows inferred combat roles in the overlay and `/fsaura roles` report.
- Keeps role evidence separate from Aura-provider assignments.
- Waits five seconds after Manastorm entry before reporting Aura readiness.
- Suppresses loading-time Aura alerts so entry produces one settled audit.
- Parses recruitment whispers for role, Aura availability, and level.
- Can ask missing recruitment questions automatically with configurable messages.
- Captures recent raid/party chat and provides a direct group-message command.
- Reports three detected Auras without contradictory distribution warnings.
- Uses compact, non-overlapping recruitment controls and warning text.
- Lets raid leaders edit the outgoing recruitment advert in the Auras tab.
