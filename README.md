# macOS Hotkeys Without Installing Software

## Goal

This is a corporate Mac. Installing third-party software that remaps keys or runs in the
background — Karabiner-Elements, Ukelele, or anything similar — is against company policy and
usually needs admin rights I don't have anyway. But years of Windows/Linux muscle memory are
hard to give up: window tiling, switching virtual desktops, and jumping between words with
Ctrl+Left/Right.

So this script changes only what Apple itself ships and documents: built-in window tiling,
System Settings' own modifier-key remapping, iTerm2's own key-binding preferences, and the
per-user `DefaultKeyBinding.dict` / `keybindings.json` files that TextEdit, Mail, Xcode, Outlook
and VS Code already read on their own. Nothing is downloaded, compiled, installed via Homebrew,
or run with `sudo`. Nothing keeps running in the background — this is a one-shot script that
edits a handful of preferences and two small per-app config files, then exits.

## Tested

Applied and verified on a real Mac, not just checked for syntax — confirmed working end to end
in `--fn-command` mode on macOS 26 (build 25G241). A different macOS version may still change
some detail (see "Sources" at the bottom); re-check after major OS updates.

## Requirements

macOS 15 or newer, English window-menu titles, iTerm2 installed. Nothing else to download,
install, compile, or run with `sudo` — just the built-in Bash, `osascript`/JXA, and Apple's own
frameworks.

## What gets configured

Here Super means logical Command, Ctrl means logical Control.

| Shortcut | Action |
|---|---|
| Ctrl+Super+← / → | Previous / next virtual desktop |
| Super+← / → | Left / right half of the screen |
| Super+↑ | Fill the screen (this is tiling, not a separate full-screen Space) |
| Super+↓ | Undo tiling, restore previous window size |
| Ctrl+Shift+C / V in iTerm2 | Copy / Paste via iTerm2's own commands |
| Ctrl+C in iTerm2 | Sends 0x03 (ordinary interrupt) |
| Ctrl+V in iTerm2 | Sends 0x16 (ordinary terminal Control+V) |
| Ctrl+← / → in iTerm2 | Jump by word (Esc+b / Esc+f, i.e. readline/zsh word motion) |
| Ctrl+Shift+← / → in iTerm2 | Unchanged: move tab left/right |
| Ctrl+← / → in Cocoa apps (TextEdit, Mail, Xcode, classic Outlook…) | Jump by word |
| Ctrl+← / → in VS Code | Jump by word (own `keybindings.json`, any mode) |
| Ctrl+← / → in Chrome's address bar | Jump by word (same Cocoa mechanism, address bar only) |
| Ctrl+← / → in MS Teams, Telegram Desktop, Firefox | Already jumps by word — the app's own default, nothing was changed here |

**Ctrl+←/→ in iTerm2 replaces the stock Select Previous/Next Session shortcut on the same
keys.** If you rely on that session/pane switching, rebind it in iTerm2 to something else before
applying. The Shift variant (move tab) is untouched.

Automatic desktop reordering by recent use is turned off. New desktops are not created by the
script — add however many you need via Mission Control. The window-tiling shortcuts work in any
app that exposes the matching Window → Move & Resize menu items; an app without those items, with
its own conflicting shortcuts, or in full-screen mode may behave differently. Where an app accepts
Command+arrow for its own window commands, that takes the key away from ordinary text navigation.

**Super+Shift+1…9 to move a window to a numbered desktop is not implemented.** macOS has no
built-in command for that — switching to a desktop and moving a window onto it are different
operations. A UI macro via Mission Control or window-title dragging would need Accessibility/
Automation permissions and per-Mac verification; this script does not grant those permissions and
does not touch organization restrictions, so a one-shortcut, guaranteed move isn't something this
approach can promise.

### Word-jump coverage, app by app

| App | Status |
|---|---|
| iTerm2 | Works — configured by this script (see table above) |
| TextEdit, Mail, Xcode, Notes, classic Outlook | Works — `DefaultKeyBinding.dict`, configured by this script |
| VS Code | Works — `keybindings.json`, configured by this script |
| MS Teams, Telegram Desktop, Firefox | Already works out of the box — nothing to configure |
| Chrome | Address bar only (same Cocoa mechanism); page content (forms, Gmail, any textarea) is rendered by Blink and has no supported way to remap this without a system-level key interceptor, which is out of scope here |
| "New Outlook" (the toggle in the top-right corner) | Not covered — it's a web-based UI, not Cocoa; switch to classic Outlook, or see Chrome's limitation above |
| Terminal.app (not iTerm2) | Not configured by this script — see the manual steps below |

## Running it

Save `setup.command` on the Mac. Open the built-in Terminal and `cd` to its folder.
**With an existing Fn → Command remap, use `--fn-command`.** It keeps that remap and uses the
physical Control key as Linux Super. The physical keys then behave like this:

| Physical keys | Action |
|---|---|
| Fn+Control+← / → | Switch virtual desktop |
| Control+← / → | Window to left/right half |
| Control+↑ / ↓ | Fill screen / restore previous size |
| Fn+Shift+C / V in iTerm2 | Copy / Paste |
| Fn+C in iTerm2 | Interrupt |
| Fn+← / → in iTerm2 | Jump by word (replaces session/pane switching) |
| Fn+Shift+← / → in iTerm2 | Unchanged: move tab left/right |
| Fn+← / → in Cocoa apps (TextEdit, Mail, Xcode…) | Jump by word |
| Control+← / → in Cocoa apps, VS Code, Chrome's address bar | Jump by word |
| Fn+C / V elsewhere | Regular Command+C / V |

This mode assumes Fn already sends Command and the physical Control key still sends Control; it
neither checks nor changes that remap. To free up Control+↑/↓ it disables the stock Mission
Control / App Exposé shortcuts, if those weren't already changed. In iTerm2, the real Command keys
will also produce the new copy/paste shortcuts, since the app sees the same signal from them as
from the remapped Fn.

Preview:

```sh
bash setup.command --fn-command
```

Save any sessions you care about, quit iTerm2 and System Settings. Apply from Apple's Terminal:

```sh
bash setup.command --apply --fn-command
```

Log out and back in.

## Alternative scheme: real Control on Fn

Preview changes nothing and works even with iTerm2 open:

```sh
bash setup.command
```

To see the proposed physical layout first:

```sh
bash setup.command --linux-modifiers
```

To apply, quit iTerm2 normally (saving any sessions you need) and close System Settings so an
open settings window can't overwrite the change. Run from Apple's Terminal:

```sh
bash setup.command --apply --linux-modifiers
```

Then log out and back into macOS — the script does not do this for you. The `--linux-modifiers`
layout:

| Label on the physical key | Signal sent to macOS | Role in this Linux layout |
|---|---|---|
| Fn / 🌐, far left | Control | Ctrl |
| Left Control | Command | Super |
| Option | Unchanged | Alt, if not remapped before |
| Command next to Space | Unchanged | Extra Command, if not remapped before |

For example: switching desktops is physically Fn+Control+arrow, copying in iTerm2 is
Fn+Shift+C, interrupting is Fn+C. **Fn+C elsewhere does not become a plain Copy under this
scheme:** standard macOS commands still use Command+C (including the physical Control+C key).
That's a trade-off of this layout, not a full Linux-keyboard emulation.

To keep your current modifier layout as-is, use:

```sh
bash setup.command --apply
```

Then the shortcuts in the first table refer to logical keys after whatever remapping you already
have. If Fn currently sends Command, it acts as Super, and Ctrl+Shift+C is pressed on whichever
key actually sends Control.

The automatic remap looks for an existing Fn setting on a single keyboard. If it can't be
identified unambiguously, the script stops before writing anything. The same assignments can then
be made by hand in System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys. Without
another key assigned to Fn, combinations that need a real Fn aren't reachable through it.

## Word-jump outside iTerm2

`setup.command` writes `~/Library/KeyBindings/DefaultKeyBinding.dict` itself (backed up and
rolled back the same way as everything else, via `--undo`). It overrides `moveWordLeft:` /
`moveWordRight:` (Shift variants select text) in every Cocoa app: TextEdit, Mail, Xcode,
**classic Outlook** (not "New Outlook" — see above), and so on.

- Control+←/→ is always written, regardless of flags. Plain Control+arrow defaults to switching
  virtual desktops (Mission Control), and this script already moves that shortcut to
  Control+Command+arrow (see above), so plain Control+arrow is free in every mode.
- Command+←/→ (physically Fn+←/→) is only added with `--fn-command`, where the real Command key
  isn't needed for Super and would otherwise just jump to the start/end of the line.

The file needs no install step and no logout — it's picked up the next time a given app restarts.
**Doesn't work in non-Cocoa apps**: Slack, VS Code, Telegram Desktop, Firefox, and Chrome (outside
its address bar — see above) use their own text-editing stack, not Cocoa's NSResponder.

Plain Terminal.app (not iTerm2) isn't covered by this file and isn't configured by
`setup.command` — it has no documented format for writing custom shortcuts programmatically. Add
it by hand: Terminal → Settings → Profiles → [profile] → Keyboard → "+" → Command+← → action
"send text", value `\033b`; then Command+→ → "send text", value `\033f`. That's the same Esc+b /
Esc+f code readline/zsh already understand as "word back/forward".

## VS Code

`setup.command` also writes `~/Library/Application Support/Code/User/keybindings.json`, if VS
Code is installed (checked by bundle id; the step is skipped otherwise). It adds four bindings —
`ctrl+left`/`ctrl+right` → `cursorWordLeft`/`cursorWordRight`, `ctrl+shift+left`/
`ctrl+shift+right` → word-selection — scoped to text-field focus (`textInputFocus`, so the
integrated terminal is untouched). Any other bindings already in the file are kept; only those
four keys are changed. If the file contains `//` comments or doesn't parse as JSON, the script
stops before writing and asks you to add the bindings by hand instead.

## Verifying and rolling back

Check Finder or TextEdit first: new shortcuts should show up under Window → Move & Resize. Check
both arrow directions between two desktops. In iTerm2, select some plain text, copy with
Ctrl+Shift+C, paste with Ctrl+Shift+V, then run `sleep 30` and interrupt it with Ctrl+C. In
`--fn-command` mode, press the physical Fn key instead of Ctrl for that check. Separately verify
your usual Latin and Cyrillic layouts.

The script changes iTerm2's global and saved-profile key bindings while keeping every other entry
untouched. Dynamic profiles and any custom modifier remapping done inside iTerm2 itself may need
separate handling. Loading iTerm2's settings from a shared folder isn't supported — the script
stops before writing in that case. Copy/Paste menu item names are assumed to be in English.

To roll back, close iTerm2 and System Settings again, then run from Apple's Terminal:

```sh
bash setup.command --undo
```

Then log out and back in. The backup lives locally at
`~/Library/Application Support/LocalLinuxShortcuts/backup.json`. It may contain iTerm2 profile
settings — don't publish it as-is. Rollback restores only the preference keys this script
touched. If any key changed again after setup, rollback skips it and keeps the backup entry, so
it never overwrites a newer setting. Nothing from this setup runs as a background service.

## Sources

- [Apple: create your own shortcuts for app commands](https://support.apple.com/guide/mac-help/create-keyboard-shortcuts-for-apps-mchlp2271/mac)
- [Apple: window tiling and built-in shortcuts](https://support.apple.com/en-eg/guide/mac-help/mchl9674d0b0/mac)
- [Apple: changing modifier keys](https://support.apple.com/en-bh/guide/mac-help/mchlp1011/mac)
- [Apple: working in multiple Spaces](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/27/mac/27)
- [iTerm2: key-binding actions](https://iterm2.com/documentation-preferences-profiles-keys.html)
- [iTerm2: action identifiers](https://github.com/gnachman/iTerm2/blob/master/sources/Keyboard/iTermKeyBindingAction.h)

AppleSymbolicHotKeys IDs and the modifier-mapping preference format are macOS implementation
details, not a guaranteed public Apple interface. Re-check after OS updates.
