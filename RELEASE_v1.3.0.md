# FrostSeek Aura Tracker v1.3.0

This release improves recruitment and raid communication while preserving the existing Aura sensing and combat-role logic.

## Highlights

- Parses applicant whispers for Tank/Heal/DPS, Aura availability, and level.
- Optionally asks concise follow-up questions when information is missing.
- Keeps exact `aura` as the only automatic invitation trigger.
- Shows richer applicant summaries and captured reply counts.
- Adds configurable recruitment message templates.
- Adds recent group-chat reporting and direct party/raid messaging commands.
- Reports `All 3 groups are reporting an Aura` when all subgroup sensors are active, naming any subgroup with an unknown provider.
- Retains the five-second Manastorm entry settle delay.

Requires [FrostSeek 2.2.5 or newer](https://github.com/ayro-CMD/FrostSeek).
