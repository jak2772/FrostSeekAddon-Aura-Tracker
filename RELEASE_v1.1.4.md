# FrostSeek Aura Tracker v1.1.4

Dependency and documentation update for the FrostSeek-integrated Manastorm Aura manager.

## Required dependency

Install [FrostSeek 2.2.5 or newer](https://github.com/ayro-CMD/FrostSeek) before installing Aura Tracker.

Aura Tracker now:

- declares FrostSeek as a mandatory WoW addon dependency;
- records the required FrostSeek version and repository in its TOC metadata;
- verifies `FrostSeek.VERSION` at runtime; and
- shows one clear warning instead of repeatedly retrying integration when FrostSeek is too old.

## Documentation cleanup

- Moved dependency and compatibility details near the top of the README.
- Added a direct link to the original FrostSeek repository.
- Replaced corrupted directory-tree characters with readable ASCII.
- Updated installation, repository layout, and release references for v1.1.4.

## Installation

1. Install or update [FrostSeek](https://github.com/ayro-CMD/FrostSeek) to version 2.2.5 or newer.
2. Download `FrostSeek_AuraTracker-v1.1.4.zip` from this release.
3. Extract `FrostSeek_AuraTracker` into `Interface\AddOns\`.
4. Restart the client or run `/reload`.
5. Open FrostSeek and select the **Auras** tab.

All Aura tracking, recruitment, alert, provider inference, level 59 warning, and overlay features from v1.1.3 remain included.
