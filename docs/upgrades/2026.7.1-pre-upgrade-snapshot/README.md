# Pre-upgrade snapshot — openclaw 2026.7.1

Captured: 2026-08-31
Author:   pre-upgrade snapshot for 2026.7.x → 2026.8.x upgrade (epic #1509)

Files:
- config/openclaw-defaults.json.2026-08-31
- config/openclaw-test-vm.json.2026-08-31

Diff targets:
- After running `openclaw doctor --migrate`, diff each file against this snapshot
  to confirm `channels.discord.streaming` is still in the 7.x nested format.
- The snapshot does NOT track `meta.lastTouchedVersion`; if that field is bumped
  in the same PR (see gateway D2 = lds #1517), expect the diff to show that line as well.

Delete this directory after the upgrade succeeds and Doctor is verified clean.
