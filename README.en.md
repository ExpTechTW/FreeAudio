<div align="center">

<img src=".github/assets/icon.png" width="128" alt="FreeAudio">

# FreeAudio

**Audio control in the macOS menu bar: every app gets its own volume, output device and equalizer, with no audio driver to install.**

[![Release](https://img.shields.io/github/v/release/ExpTechTW/FreeAudio?label=Release&color=1B8A50)](https://github.com/ExpTechTW/FreeAudio/releases/latest)
[![Pre-release](https://img.shields.io/github/v/tag/ExpTechTW/FreeAudio?sort=date&label=Pre-release&color=orange)](https://github.com/ExpTechTW/FreeAudio/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/ExpTechTW/FreeAudio/release.yml?branch=main&label=Build)](https://github.com/ExpTechTW/FreeAudio/actions/workflows/release.yml)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#download)
[![Discord](https://img.shields.io/discord/926545182407688273?logo=discord&logoColor=white&label=Discord&color=5865F2)](https://discord.gg/5dbHqV8ees)

[繁體中文](README.md) • **English** • [日本語](README.ja.md)

[Download](https://github.com/ExpTechTW/FreeAudio/releases/latest) • [Changelog](https://github.com/ExpTechTW/FreeAudio/releases) • [Report a problem](https://github.com/ExpTechTW/FreeAudio/issues)

</div>

## What is FreeAudio

FreeAudio is a macOS audio tool that lives in the menu bar. Besides switching devices and setting their volume, it gives every app its own volume, output device and equalizer, and it can play your sound on several devices at once.

It works through the Core Audio process taps built into macOS, so there's no virtual audio driver to install. Only the apps you adjust go through FreeAudio; everything else plays straight to the hardware as usual.

## What it does

| | |
|---|---|
| **Input and output** | Switch speakers and microphones, and set their volume and mute. Devices without a volume control of their own, such as HDMI displays, get one from FreeAudio |
| **Per-App Volume** | Give each app a volume from 0 to 200%, mute, left/right balance and a 10-band equalizer, its own output device, or several devices at once. Helper processes of browsers and Electron apps count as their app |
| **Global Multi-Output** | Play all your sound on several devices at once. Check the devices under Output, like choosing AirPlay speakers; each one has its own volume, mute, balance and equalizer. Individual apps can be left out |
| **Equalizer** | Built to the Music app's specification: 10 bands from 32 Hz to 16 kHz, ±12 dB, a preamp, and the Music app's 22 presets with the same names and values |
| **Keep Chosen Devices** | Only the speaker and microphone chosen in FreeAudio are used. When macOS switches to headphones as they connect, or you switch in Control Center, FreeAudio switches back. If the chosen device is missing, whatever macOS picked instead is muted and you're told, rather than moving to another device |
| **Quiet new devices** | A speaker or microphone connected for the first time starts at 0% and muted, so nothing plays or listens by surprise |
| **Microphones stay muted** | A microphone muted in FreeAudio only opens again when you unmute it in FreeAudio. When macOS unmutes it by itself, for Siri or when a call changes devices, FreeAudio mutes it again at once. The menu bar icon is a red slashed microphone while the microphone is muted or unavailable |
| **Remembers your sound** | Devices, volume and mute are remembered and come back after a restart |
| **Automatic updates** | Updates come from GitHub, notarized by Apple, and FreeAudio only installs builds signed by its own developer. You can choose to get pre-releases |
| **Three languages** | 繁體中文, English and 日本語, following the system unless you choose one in Settings |

## Download

FreeAudio needs **macOS 26 or later**, on Apple silicon or Intel.

1. Download `FreeAudio-<version>.zip` from [Releases](https://github.com/ExpTechTW/FreeAudio/releases/latest), unzip it, move FreeAudio.app to your Applications folder and open it. It's notarized by Apple, so it opens straight away.
2. The first time you adjust an app, macOS asks for System Audio Recording access: choose Allow. You can also press Allow Access… in the menu bar panel or in Settings.
   - If no dialog appears, open System Settings › Privacy & Security › Screen & System Audio Recording, and add FreeAudio with + under System Audio Recording Only.
   - If you chose Don't Allow before, turn FreeAudio on in that same list.
3. To have your sound settings restored after a restart, turn on Open at Login in Settings.

FreeAudio checks for updates when it starts and every 6 hours after, and tells you when a new version is out; Check Now in Settings › Updates checks right away. If the menu bar icon is hidden, open FreeAudio again (from Finder or Spotlight) to show its Settings window.

### Releases and pre-releases

| | Name | Published |
|---|---|---|
| Release | `26.1`: year and number | By hand |
| Pre-release | `26w39a`: year, week, and which of that week's builds | Automatically, with every push to `main`; unreviewed, so it may have problems |

To try new builds early, turn on Get Pre-releases in Settings › Updates. A release only updates to releases, and a pre-release only to pre-releases. The bottom of the menu bar panel shows the version in use, with an orange label for a pre-release and a green one for a release.

## Known limitations

- FreeAudio can't run alongside other tap-based audio tools (BetterAudio, SoundSource, FineTune and the like), or sound is processed twice; the panel points it out when it sees one.
- A browser plays all of its tabs from one audio process, so the whole browser is adjusted together.
- Sound that goes through FreeAudio is delayed very slightly.
- Siri's voice processing may ignore a muted microphone. To be sure Siri can't hear you, turn off Siri's listening in System Settings.

## Development

Building FreeAudio needs macOS 26 or later and Xcode 26 or later.

```bash
git clone https://github.com/ExpTechTW/FreeAudio.git
cd FreeAudio
git config core.hooksPath .githooks   # check commit messages as you commit
swift test                            # run the tests
scripts/build-app.sh                  # build build/FreeAudio.app
open build/FreeAudio.app
```

- `scripts/build-app.sh` signs with a certificate from your keychain: Developer ID Application first, then Apple Development. With neither, it signs ad hoc, so macOS asks for permission again after every build and the app can't update itself.
- `swift run` works too, but the permission is then granted to your terminal; the bundled app is the better choice.
- Commit messages are the changelog. Their format is in [commit.md](commit.md) (in Traditional Chinese), and a git hook and CI check it.

### How it works

FreeAudio only processes the apps and devices whose settings you changed. Each "route" is a process tap plus a private aggregate device: the tap captures the app's sound and silences its own output, and FreeAudio applies volume, balance, equalizer and a limiter in the IO callback before playing it on the target device.

- An app that follows the system output is captured only on its way to that device; an app sent to a device of its own is captured in full.
- The output devices' equalizers and Global Multi-Output use taps that leave out FreeAudio itself and other audio tools, so there's no feedback.
- Routes only start when there's sound, and go back to waiting 15 seconds after an app stops playing, so output devices can sleep.
- When an output device is itself an aggregate (such as a Multi-Output Device), its member devices make up the route.

| File | What's in it |
|---|---|
| `AudioController.swift` | Watches devices and processes, and decides which routes are needed |
| `RoutePlan.swift`, `MultiOutput.swift` | Works out the routes from the settings; the checking rules of Global Multi-Output |
| `AudioRoute.swift`, `DSP.swift` | Taps and aggregate devices; real-time processing (equalizer, gain, limiter, channel mapping) |
| `Devices.swift`, `DeviceLock.swift`, `MicrophoneHold.swift` | Devices, volume and mute; Keep Chosen Devices; keeping microphones muted |
| `Processes.swift`, `Permission.swift` | Grouping processes by app; the System Audio Recording permission |
| `Settings.swift` | Settings, equalizer presets and saving them |
| `TrayView.swift`, `SettingsView.swift`, `Components.swift` | The menu bar panel, the Settings window and shared controls |
| `Update.swift`, `Updater.swift` | Automatic updates: comparing versions, downloading, verifying and replacing |
| `Localization.swift` | Interface languages |

### Where the equalizer comes from

- Bands and range: the Music app's AppleScript dictionary (`Music.app/Contents/Resources/com.apple.Music.sdef`) lists 10 bands from 32 Hz to 16 kHz, each band and the preamp ranging from −12 to +12 dB.
- Presets: all 22 are copied as they are from `~/Library/Preferences/com.apple.Music.eq.plist` (`eqps:129:EQPresets`, in 0.01 dB). Their names are the Music app's localized ones, including the five it renamed, such as Increase Bass.
- Filters: the Music app doesn't publish its filter shapes; FreeAudio uses an octave-wide peaking filter (Audio EQ Cookbook) for each band.

### Publishing

The rules follow DPIP's (`.github/workflows/release.yml`):

- A push to `main` publishes a pre-release on GitHub, tagged with its name (for example `26w39a`).
- A `v<yy>.<n>` tag publishes a release, for example `git tag -a v26.1 -m 26.1 && git push origin v26.1`.

Every build is signed with Developer ID, notarized by Apple, and its changelog is posted to Discord.

- `scripts/version.sh` works out the version from the git history. `CFBundleVersion` is the build code: `1`, the two-digit year, and the commit's number within that year (for example `126000027`), so it only ever goes up. The app compares it to decide which build is newer, within the same channel only.
- `scripts/notes.sh` writes the changelog from the commits' entry lines: a pre-release lists the changes since the previous build, and a release everything since the previous release.
- The app checks for updates through GitHub's public API, so the repository has to be public.

CI uses these secrets:

| Secret | What it holds |
|---|---|
| `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD` | The Developer ID Application certificate and its private key, exported as a .p12 and base64-encoded, and its password |
| `APPLE_TEAM_ID` | The team ID |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` | The Apple ID for notarization, and an app-specific password made at account.apple.com |
| `DISCORD_WEBHOOK` | Optional: the Discord webhook that announces each changelog |

The first five share their names with TREM-Lite's, and `scripts/set-apple-secrets.sh` sets them on several repositories at once. It checks the .p12 the way CI will use it first, and hands the values to `gh` on standard input only:

```bash
scripts/set-apple-secrets.sh DeveloperID.p12 ExpTechTW/FreeAudio ExpTechTW/TREM-Lite
```
