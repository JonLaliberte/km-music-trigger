# km-music-trigger

Runs a [Keyboard Maestro](https://www.keyboardmaestro.com) macro when Apple Music starts, pauses or stops playing, or changes track.

## Why this exists

Keyboard Maestro has no trigger for playback. The only option on the
[KM forum](https://forum.keyboardmaestro.com/t/how-to-detect-an-itunes-track-change/5879) is to poll
Music with AppleScript every few seconds. That gives slow reactions, and it starts a new process on every check.

Apple Music already announces every playback change. It posts a system-wide distributed notification
called `com.apple.Music.playerInfo` with the player state, track name, artist and album. This is a tiny
background program that listens for that notification and calls your macro. It uses no CPU while idle
and never polls Music.

I built it to reconnect my Bluetooth headphones the moment music starts. It works for anything you want
to happen on play, pause or a new track: lights, Do Not Disturb, logging, scrobbling and so on.

> The notification is undocumented, though it is not a private API. iTunes has sent it for years, and
> Music has sent it since macOS Catalina. Tested on macOS 27.2. Apple could change it someday.

## What your macro receives

The event is passed as the macro's parameter, so read it with the `%TriggerValue%` token:

| Event | When |
|---|---|
| `playing` | playback started or resumed |
| `paused` | playback paused |
| `stopped` | playback stopped |
| `track` | a new track started while playing (only if you enable it with `--on`) |

With `--json`, `%TriggerValue%` is a JSON object instead:

```json
{"album":"…","artist":"…","event":"playing","name":"…","state":"Playing"}
```

To read the fields, first store `%TriggerValue%` in a variable (for example `Local_Info`) with
**Set Variable to Text**. Then use KM's JSON token: `%JSONValue%Local_Info.name%`.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/JonLaliberte/km-music-trigger.git
cd km-music-trigger
make install            # builds and copies the binary to ~/.local/bin/km-music-trigger
```

### 1. Pick the macro

In Keyboard Maestro, select your macro and choose **Edit → Copy as → Copy UUID**. A macro name works
too, but the UUID still works if you rename the macro.

### 2. Try it in the foreground

```sh
~/.local/bin/km-music-trigger --macro 8C9DDE2C-0000-0000-0000-000000000000 --verbose
```

Press play/pause in Music. The first time it calls the macro, macOS asks to allow your terminal (or
`km-music-trigger`) to control **Keyboard Maestro Engine**. Click Allow. Press Ctrl-C to stop.

### 3. Run it in the background at login

```sh
make agent MACRO=8C9DDE2C-0000-0000-0000-000000000000            # default events: playing,paused,stopped
make agent MACRO=… ON=playing                                    # only when playback starts
make agent MACRO=… ON=playing,track JSON=1                       # track changes too, with JSON details
```

This writes `~/Library/LaunchAgents/com.github.jonlaliberte.km-music-trigger.plist` and loads it.
launchd starts it at login and restarts it if it exits. When it first runs the macro, macOS shows a
prompt for `km-music-trigger` to control Keyboard Maestro Engine. Allow it. If you miss the prompt,
turn it on in **System Settings → Privacy & Security → Automation**.

The log is at `~/Library/Logs/km-music-trigger.log`. It logs one line per event that runs your macro.
It trims itself: once it passes 100 KB it keeps only the most recent 50 KB.

```sh
make status       # is it running?
make uninstall    # unload the agent and remove the binary
```

To run several macros, either make one macro that branches on `%TriggerValue%` and calls the others
(simplest), or copy the plist with a different label and macro.

## Options

```
-m, --macro <name|UUID>  Macro to run (required)
-e, --on <list>          playing, paused, stopped, track   (default: playing,paused,stopped)
-j, --json               pass JSON instead of the event name
-n, --dry-run            print what would run, don't call Keyboard Maestro
-v, --verbose            log every notification, including ignored repeats
```

The same settings can come from the environment: `KMMT_MACRO`, `KMMT_ON`, `KMMT_JSON=1`.

## Notes

- Music sends several notifications per change. On a pause the first one still says "Playing".
  km-music-trigger waits 0.25 s, uses the last one, and runs the macro only when the state (or track)
  actually changes.
- It listens only to `com.apple.Music.playerInfo`. Music also sends a copy as
  `com.apple.iTunes.playerInfo`, and listening to both would run your macro twice.
- In early testing, one play went undetected right after the listener started. I couldn't reproduce
  it. If you depend on catching every event, keep a slow periodic trigger on your macro as a backstop.
- It doesn't know about Spotify or other players, only Apple Music.

## License

MIT
