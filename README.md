# ma-flac-sync-patch

Local workaround patch for [Music Assistant](https://github.com/music-assistant/server) 2.8.7 that restores audible synchronised playback on classic Logitech Squeezebox devices (Boom / Radio / Touch).

## Symptom

Group two or more classic Squeezeboxes for synchronised playback → Music Assistant shows **"playing"**, drift correction is running, slimproto connections stay stable — **but no audio comes out of the speakers**. Solo playback on every single device works fine.

In the Music Assistant logs (with the `Squeezelite` provider set to `log_level=DEBUG`):

```text
DEBUG Squeezelite          Start serving multi-client flow audio stream to Musik Buero Dir
WARN  aioslimproto.client  Musik Buero Dir: Player did not report support for content_type audio/flac, playback might fail
DEBUG Squeezelite          Start serving multi-client flow audio stream to Musik Kuech
WARN  aioslimproto.client  Musik Kuech: Player did not report support for content_type audio/flac, playback might fail
DEBUG Squeezelite          Musik Buero Dir resync: skipAhead 25ms
DEBUG Squeezelite          Musik Buero Dir resync: skipAhead 523ms  ← drift correction running
…
```

Evidence in the MA UI Pipeline overlay: even after setting per-player `output_codec = mp3`, the output block still reads `flac 44.1 kHz / 16 bits`.

## Root cause

In `music_assistant/providers/squeezelite/player.py` (Music Assistant 2.8.7) the format parameter of the multi-client stream URL is hardcoded:

```python
# line 281
base_url = (
    f"{self.mass.streams.base_url}/slimproto/multi?player_id={self.player_id}&fmt=flac"
)
```

The per-player `output_codec` setting is only honoured on the solo playback path (`resolve_stream_url(...)`), not on the multi-client sync path. Classic Logitech Squeezebox firmware does **not** advertise `flc` in its slimproto HELO capability list; it accepts the FLAC stream anyway, its decoder appears to run (`STAT` position counter advances, MA's `_handle_buffer_ready` is happy) — but the DAC output is silence.

## What this patch does

A single change: `fmt=flac` → `fmt=mp3`. Classic Squeezeboxes have a **hardware MP3 decoder** and start playing cleanly in sync immediately.

Drift correction continues to operate in the millisecond range (we measured 18–30 ms in our tests), and there are no more premature stream disconnects.

## How to apply

### Quickest: run on the Docker host

```bash
./apply-patch.sh                  # patches the 'music-assistant' container and restarts it
./apply-patch.sh --no-restart     # patches only, no restart
./apply-patch.sh --revert         # reverts to the latest .bak.YYYYMMDD_HHMMSS
CONTAINER=my-mass ./apply-patch.sh  # if your container is named differently
```

The script is idempotent (recognises an already-patched file), takes a backup before every change, and polls the `/info` endpoint after restart to confirm MA is back up.

### Manually

```bash
docker exec music-assistant sed -i 's|fmt=flac|fmt=mp3|g' \
    /app/venv/lib/python3.13/site-packages/music_assistant/providers/squeezelite/player.py
docker restart music-assistant
```

### As a git patch

If you have a Music Assistant source tree (e.g. a local fork):

```bash
git apply --3way squeezelite-sync-mp3.patch
```

## Important caveats

- **Every MA image update wipes the patch.** Re-run `apply-patch.sh` after each upgrade.
- **The patch only helps classic Squeezeboxes** (Boom / Radio / Touch). Modern software-based Squeezelite clients and SqueezeESP32 devices with recent firmware do support FLAC and don't need this patch — but switching to MP3 doesn't hurt them either.
- If you need **lossless audio in sync mode**: patch to `fmt=pcm` instead of `fmt=mp3`. That's roughly 1.4 Mbps per player at 44.1/16 — fine on a clean LAN, marginal across hops.

## Pre-merge verification: deploy the upstream-PR fix

`apply-fork-patch.sh` (sibling of `apply-patch.sh`) installs the in-progress
upstream fix — the same code being proposed at `digodigo/server:fix/squeezelite-sync-honor-per-child-format`
— into the running 2.8.7 container, so it can be verified on real Squeezebox
hardware before the upstream PR is merged.

Unlike the one-line `apply-patch.sh`, this script `docker cp`s a fully-rewritten
`player.py` (stored under `fork-patch/`). The fix resolves each child's codec
independently from per-player config + slimproto HELO, so mixed groups
(e.g. a Boom + a Touch) no longer share a single LCD codec — the Touch keeps
FLAC, the Boom gets MP3.

```bash
./apply-fork-patch.sh                # apply + restart
./apply-fork-patch.sh --no-restart   # apply only
./apply-fork-patch.sh --revert       # restore previous .bak.* and restart
CONTAINER=my-mass ./apply-fork-patch.sh
```

Once the upstream PR is merged and released, both scripts become obsolete.

## Recommended companion settings

In the MA UI (Settings → Player → \[Player\] → Configure), for the classic Squeezeboxes:

- `output_codec = mp3` (active on the solo path, harmonises with the patch on the sync path)
- `sample_rates = ['44100||16']` (Booms are natively 44.1/16 — saves a resampling stage)

## Upstream status

As of 2026-05 the Music Assistant docs describe the sync-group "Fixed 96 kHz / 24-bit output format" as a deliberate property; the codec aspect of the same hardcoding is not publicly documented as a bug. The closest existing topic is [Discussion #5113](https://github.com/orgs/music-assistant/discussions/5113), which has had no maintainer reply since March 2026.

A full bug report with diagnosis, DEBUG log evidence and a verified patch reference has been filed upstream:

- Music Assistant bug report: **https://github.com/music-assistant/support/issues/5506**

## Tested with

- Music Assistant Server 2.8.7 (Docker, `ghcr.io/music-assistant/server:latest`)
- 4× Squeezebox Boom (original firmware)
- 5× Squeezebox Radio (original firmware)
- 1× Squeezebox Touch (original firmware)
- 2× Muse Luxe (SqueezeESP32, philippe44 firmware)
- Sources: filesystem_local (MP3 / FLAC), Spotify, RadioBrowser
