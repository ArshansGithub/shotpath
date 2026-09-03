# ShotPath

A tiny macOS menu bar app that turns the native screenshot flow into a **file path on
the clipboard** instead of an image on the clipboard.

## Why

When you paste an image into Claude Code, the image is carried in the conversation as
an inline block. On the next request that block gets re-rendered as a text pointer
rather than replayed as the original bytes. Two things break at once: the prompt prefix
changes, so the whole context has to be rewritten and the prompt cache is invalidated,
and the picture itself silently drops out of the model's context. You paid for the
image once, then lost both the image and the cache.

If the model instead **reads the image from a path**, the image arrives as a tool
result. Tool results are replayed byte-for-byte on every subsequent turn, so the prefix
stays stable, the cache keeps hitting, and the image stays in context for the rest of
the session. ShotPath makes that the default: press the usual screenshot shortcut, get
a path like `/Users/you/shots/20260902-220807.png` on your clipboard, paste it into
Claude Code, and let it Read the file.

## Why this is cheaper, with the receipt

Measured on Claude Code 2.1.259, `claude-fable-5-1[1m]`, a 232k-token agentic session, one 136 KB phone screenshot pasted:

| request | cache_read | cache_creation | what happened |
|---|---|---|---|
| turn before | 231,751 | 828 | hit |
| turn with the pasted image | 83,834 | **158,694** | the image block was re-rendered as a text pointer; prefix broke at that message |
| turns after | climbing again | small | hits, but the model no longer has the image |

One paste cost a 159k-token cache write (roughly $3 at Fable 5.1's 1h write rate) and the picture left the model's context. Every later question about the screenshot was answered from the model's own earlier description of it.

The same image delivered as a file path and Read by the model:

| | pasted | Read from path |
|---|---|---|
| image tokens on the turn it's introduced | ~1,500 | ~1,500 |
| cache rewrite on the next turn | the whole suffix after that message | none, tool results are replayed byte-for-byte |
| image still in context ten turns later | no (pointer text only) | yes |
| per-turn cost of keeping it | 0 | ~1,500 **cached** tokens, ≈ $0.0004 |

Keeping the image costs a fraction of a cent per turn. Dropping it costs one rewrite of everything after it, at the largest context the session has reached, plus the image. The pointer swap is strictly worse on both axes, which is why ShotPath routes around it.

### Where the token number comes from

Anthropic bills roughly `width × height / 750` tokens per image and downscales anything whose longer edge exceeds 1568 px before counting. So resolution, not file size, sets the cost, and there is a hard ceiling of about 1,600 tokens per image. A 1179×2556 phone screenshot becomes 723×1568 ≈ 1,510 tokens. Cropping to the dialog that matters (say 600×400 ≈ 320 tokens) is the only lever that reduces cost below the ceiling, which is what the crop window is for. Downscaling to 1568 px before saving removes bytes the model would never see and makes the Read tool result smaller without changing what the model gets.

### Related

Filed as a Claude Code issue with the same capture: <IMG link>. Part of a larger dissection of Fable 5.1 usage through Claude Code: <CC-HUB link>.

## What it does

When enabled, ShotPath points the system screenshot tool at a private inbox directory,
watches that directory, and for every screenshot that lands there:

1. Waits until the file size has been stable for 300 ms.
2. Downscales it so the longer edge is at most **1568 px**. That is Anthropic's image
   ceiling; anything larger costs bytes and upload time but not tokens.
3. Saves it as PNG to `~/shots/YYYYMMDD-HHMMSS.png`.
4. Puts `Read the screenshot at <absolute path>` on the clipboard as plain text. A bare image path is auto-inlined by Claude Code as a pasted image, which is the exact behavior this avoids; the phrase keeps it text so the model calls `Read`. Change the prefix with `defaults write com.local.shotpath ShotPathClipPrefix "..."`.
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
