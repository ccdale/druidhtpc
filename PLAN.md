# druidhtpc / ccatv Operational Plan

This repo is the long-term target for the rebuilt HTPC. The ccatv service layout and packaging plan should be kept here so the rebuild can proceed without depending on editor state.

## Near-Term Work

1. Convert current ccatv into three `systemd --user` services.
	- `ccatv.service` for recorder and scheduler duties.
	- `ccatv-api.service` for the local HTTP transport.
	- `ccatv-web.service` for the Flask UI.
	- Keep runtime config under `$HOME/.config/ccatv/`.
	- Use journald as the primary logging backend.

2. Validate that split on the current `druidmedia` Mint 22.3 machine.
	- Confirm the services start and restart independently.
	- Confirm recordings continue when the desktop session is absent.
	- Confirm logs are available per unit via `journalctl --user`.
	- Confirm Kodi and IceWM remain separate from ccatv supervision.

## Deferred Work

3. Create an installable AUR package for ccatv from GitHub release artifacts.
	- Package the Python app, service units, and config scaffolding.
	- Leave secrets and machine-specific runtime values in `$HOME/.config`.

4. Apply the same service model to the rebuilt Arch-based `druidhtpc` machine.
	- Keep the 3-service split as the canonical runtime shape.
	- Keep ccatv independent of the desktop session and Kodi lifecycle.

## Notes

- This is the planning anchor for the rebuild work.
- Keep it updated as implementation decisions change.