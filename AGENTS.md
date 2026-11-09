# Release policy

- Publish all Typer updates to **Stable**. Use the stable release workflow and signed stable appcast.
- **Do not publish to Edge**, upload new Edge assets, refresh the Edge appcast, or enable the Edge publishing workflow unless the human user explicitly asks to restore Edge publishing.
- Keep the existing Edge release as an archive. Its presence is not permission to update it.
- A Stable release must not require an Edge build. Validate the selected source commit with tests, native playback smoke checks, and signature verification.
- Preserve the user's saved profiles, samples, settings, and unfinished runs when testing or installing updates.
