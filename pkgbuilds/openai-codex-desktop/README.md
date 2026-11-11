# ChatGPT Desktop on Omarchy

## Playback stays quiet after dictation

The Linux dictation helper can leave an app's audio stream at reduced gain if the stream closes while dictation is active. The mixer can still show its usual channel volume. [OpenAI issue #60537](https://github.com/openai/codex/issues/60537)

If this keeps happening, add the following line to `~/.config/codex-flags.conf`, then quit ChatGPT Desktop completely and reopen it.

```text
--omarchy-disable-dictation-ducking
```

This stops the affected helper from lowering other apps' volume during dictation. It takes effect on subsequent recordings. To bring back automatic ducking, remove the line and restart the app.
