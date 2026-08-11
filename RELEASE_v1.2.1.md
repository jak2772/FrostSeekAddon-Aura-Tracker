# FrostSeek Aura Tracker v1.2.1

Manastorm entry alert stabilization hotfix.

## Fixed

- Increased the entry settle window from 2.5 to 5 seconds.
- Continues updating internal roster and Aura state silently while players load.
- Suppresses distribution and provider join/leave announcements during the grace window.
- Uses the final five-second scan as the new alert baseline.
- Sends one settled Manastorm audit instead of an early failure followed by success.

Combat role inference from v1.2.0 remains included.

## Required dependency

[FrostSeek 2.2.5 or newer](https://github.com/ayro-CMD/FrostSeek)
