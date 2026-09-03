# ShotPath

A tiny macOS menu bar app that turns the native screenshot flow into a **file path on
the clipboard** instead of an image on the clipboard. See the correction below before assuming it saves you anything on prompt caching: it does not.

## What it is

When enabled, the normal screenshot shortcut puts a **file path on your clipboard** instead of an image. Paste the line into Claude Code and the model reads the file with its `Read` tool. The screenshot is downscaled to Anthropic's 1568 px image ceiling before it is saved (anything larger costs upload bytes but not tokens), and a crop window lets you hand over only the part of the screen that matters, which is the one lever that actually reduces image tokens.

## Correction, Sep 3 2026

The first version of this README claimed that pasting an image into Claude Code costs a full prompt-cache rewrite and that the model loses the image on the next turn. **That was wrong, and I retracted it** ([anthropics/claude-code#91705](https://github.com/anthropics/claude-code/issues/91705), closed).

Request bodies captured on both sides of a pasted image over ~800 later requests show the pasted message keeps the same three blocks every time: the text, the base64 image block, and a `[Image: source: …]` pointer that Claude Code sends *alongside* the image from the first request. The image bytes are identical in every request, so the prefix never breaks at that message and the model keeps the image. The cache collapse I attributed to the paste was a persisting `cd` in the same session rewriting the system prompt on the next turn ([#91706](https://github.com/anthropics/claude-code/issues/91706)), which happened to be the turn carrying the image.

So: pasting and `Read`ing are equivalent for the cache. ShotPath does not save you a rewrite. What it does is deliver the screenshot as a file the model can re-read at full resolution, downscale to the token ceiling, and let you crop before sending. If that's useful to you, it works; if you only wanted the cache fix, there is nothing to fix.

The full investigation this came out of, with the retraction left in: [claude-code-fable-usage](https://github.com/ArshansGithub/claude-code-fable-usage).

## What it does

When enabled, ShotPath points the system screenshot tool at a private inbox directory,
watches that directory, and for every screenshot that lands there:

1. Waits until the file size has been stable for 300 ms.
2. Downscales it so the longer edge is at most **1568 px**. That is Anthropic's image
   ceiling; anything larger costs bytes and upload time but not tokens.
3. Saves it as PNG to `~/shots/YYYYMMDD-HHMMSS.png`.
4. Puts `Read the screenshot /Users/you/shots/20260902-221500 (add .png)` on the clipboard as plain text. Claude Code's paste handler inlines any image path it finds in pasted text, wherever it sits, so the path is handed over **without its extension** and the model adds it back when it calls `Read`. Verified on 2.1.259: the paste stays text and the image arrives as a tool result. Change the prefix with `defaults write com.local.shotpath ShotPathClipPrefix "..."`.
5. Deletes the inbox copy and reports `path copied (WxH, ~N tokens)`.

Files in `~/shots` older than 24 hours are deleted on launch and hourly.

## Menu

| Item | Effect |
|---|---|
| Enabled | Toggles the whole mechanism, including the two system defaults below. Persisted in `UserDefaults`. |
| Crop last shot… | Opens the last shot, drag a rectangle, writes `~/shots/<name>-crop.png` at native resolution and copies that path. |
| Open ~/shots | Reveals the output directory in Finder. |
| Start at Login | Registers or unregisters via `SMAppService` (macOS 13+). |
| Quit | Quits. |

## Build and run

```
./build.sh
open build/ShotPath.app
```

Requires Swift 6.x and macOS 13 or newer. No third-party dependencies. The build is a
single `swiftc` invocation and an ad-hoc codesign, producing `build/ShotPath.app`.

Command line flags: `--enable`, `--disable`, `--install-login-item`,
`--uninstall-login-item`, `--selftest-crop [image]`.

## The two system defaults it writes

Enabling runs exactly these three writes:

```
defaults write com.apple.screencapture target file
defaults write com.apple.screencapture location ~/Library/Application\ Support/ShotPath/inbox
defaults write com.apple.screencapture show-thumbnail -bool false
```

The third turns off the floating corner preview while ShotPath is enabled: macOS does not write the screenshot file until that preview dismisses, which made the path appear seconds late. It is restored on disable like the other two.

Disabling restores whatever those three keys held **before ShotPath first touched them**.
The prior values are snapshotted on the first enable, so the restore is exact rather
than a guess at a default. To undo by hand, for a machine whose original setting was
the stock one:

```
defaults write com.apple.screencapture target clipboard
defaults delete com.apple.screencapture location
defaults delete com.apple.screencapture show-thumbnail
```

No `killall` is needed. See the macOS 26 note below.

## Token estimate

```
N = ceil(W * H / 750)
```

`W` and `H` are the pixel dimensions of the file that was actually written, after
downscaling. A full 1568 px capture from a 3:2 display lands around 2,185 tokens.

## macOS 26 note

On macOS 26.5.2 the two defaults take effect immediately, with no `killall
SystemUIServer` and no logout. Verified two ways. A value written by one process is
readable by a separate freshly launched process straight away and is already flushed to
`~/Library/Preferences/com.apple.screencapture.plist`, because `defaults` writes go
through `cfprefsd` rather than a per-app cache. And nothing resident holds the
preference: `SystemUIServer` is still running on macOS 26 but is not part of the
screenshot path, while `Screenshot.app` and `/usr/sbin/screencapture` are launched fresh
per capture and read the preference at capture time.

## Notifications

The app asks for User Notifications permission on launch. An ad-hoc signed build run
from a user directory is usually refused outright by the notification daemon, so
ShotPath also flashes the message next to the menu bar icon for four seconds. That
fallback always runs, so you get feedback whether or not banners are permitted.

## Credits

Built by [Arshan](https://github.com/ArshansGithub) with Claude Fable 5.1, during a night spent finding out why Claude Code + Fable 5.1 was burning through a usage window. The screenshot-paste rewrite was one of the causes; this is the workaround.

MIT licensed. Issues and PRs welcome.
