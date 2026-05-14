# Ribbind

🌐 **English** · [한국어](./README.ko.md)

Bind any keyboard shortcut to any Microsoft Word, PowerPoint, or Google Chrome command on macOS — including Ribbon-only buttons that System Settings can't reach. Currently **v0.6.1**.

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## Install / Update

Open Terminal (`⌘ + Space` → `Terminal`).

**1. Install Apple Command Line Tools** (one-time, free):

```sh
xcode-select --install
```

**2. Run the install block.** Same command for first install and every update — wipes any prior source clone, fetches the latest from GitHub, builds, and installs into `/Applications/`:

```sh
mkdir -p ~/Downloads && cd ~/Downloads
rm -rf ribbind
git clone https://github.com/minguk2/ribbind.git
cd ribbind
scripts/build-app.sh release
pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1
rm -rf /Applications/Ribbind.app
mv dist/Ribbind.app /Applications/
open /Applications/Ribbind.app
```

Build is ~30 s. Ribbind lives in the menu bar (no Dock icon).

**3. Grant Accessibility** when prompted, plus **Automation** the first time you fire a Word / PowerPoint / Chrome shortcut. Each is a single click in a system dialog.

After updates, you may need to remove and re-add Ribbind in System Settings → Privacy & Security → Accessibility (rebuilds rotate the code signature).

Open Settings from the menu bar icon, or `⌘,`.

---

## What you can bind

### PowerPoint

![PowerPoint settings tab](docs/screenshots/settings-powerpoint.png)

- **Format** — Format Painter, Font Color 1/2/3 (RGB picker), Font Family
- **Picture** — Crop, Lock Aspect Ratio
- **Shapes** — Text Box, Oval, Rectangle, Rounded Rectangle, Down Arrow, Left Arrow
- **Slide Show** — Hide Slide

The four menu-accessible shapes arm PowerPoint's drag-to-create cursor (just like clicking Insert → Shape).

### Word

![Word settings tab](docs/screenshots/settings-word.png)

- **Format** — Format Painter, Highlight 1/2/3 (named color), Font Color 1/2/3 (RGB), Font Family
- **Picture** — Crop, Lock Aspect Ratio

Highlights write Word's native `<w:highlight>`, so the Home ribbon's *No Color* button clears them normally.

### Google Chrome

![Google Chrome settings tab](docs/screenshots/settings-chrome.png)

- **Translate Page (toggle)** — pick any of 18 target languages. Press once → page translates in place via Chrome's on-device Translator API. Press again → restore.

No cursor movement, no UI flicker, no API key, no network at translation time.

Two one-time setup gates surfaced in the Chrome tab itself:
1. *Chrome > View > Developer > Allow JavaScript from Apple Events* (per-profile toggle).
2. Click **Initialize translation model** in Ribbind, then click any spot on the Chrome page once. Chrome downloads the on-device model (~50 MB per language pair).

### Per-binding parameters

Each Highlight / Font Color / Font Family / Translate row carries its own picker — color swatch, RGB well, font menu, or language menu. State persists across export / import.

Orange ⚠ marks Ribbon-only commands (those without an AppleScript fallback). *Crop* and *Lock Aspect Ratio* additionally need an image to be selected before the shortcut fires.

**Need something else?** Click *Add from Word…* / *Add from PowerPoint…*; Ribbind reads any Ribbon button or menu item live. **[Open an issue](../../issues/new)** for new features.

---

## Permissions

![General settings tab](docs/screenshots/settings-general.png)

| Permission | When | Why |
|---|---|---|
| **Accessibility** | First launch | Catch shortcuts before Office / Chrome sees them. |
| **Automation** (Word / PPT) | First Word / PPT shortcut | Apply formatting, insert shapes. |
| **Automation** (Chrome) | First Translate shortcut | Run translation JS in the active tab. |

Plus one Chrome-side toggle (not a system permission): *View > Developer > Allow JavaScript from Apple Events*. Ribbind's Chrome tab opens it for you.

The **General** tab shows live status: Accessibility check, Office detection, Launch at login, Import / Export.

---

## FAQ

**Shortcut does nothing?** Check (1) the target app is foreground, (2) Accessibility is granted to the *current* `/Applications/Ribbind.app` (rebuilds rotate the signature — re-add Ribbind in System Settings → Accessibility), (3) PowerPoint menu shortcuts only register at launch — quit and reopen.

**Chrome ⌃⌘T does nothing or shows a notification?** Both setup gates must be green in Settings → Google Chrome. Click *Initialize* and follow the prompt for the first model download. On a large page the first press can take a few seconds to translate — wait for the page to settle before pressing again. Press too soon and you'll see a *Translation in progress* notification (the next press is held back so the toggle state stays consistent).

**Notification says "Couldn't detect page language"?** The page has no `<html lang>` attribute and Chrome's `LanguageDetector` API didn't return a result. Reload the tab or pick one with normal HTML.

**Apple Developer account needed?** No. The install uses Apple's free Command Line Tools.

**Internet?** Only Chrome's one-time model download. Translation runs on-device after that. No telemetry, no auto-update.

**Will it conflict with my Word customizations?** No — Ribbind writes to the same files Word's *Customize Keyboard* uses. Most-recent assignment wins on collision.

**Update?** Run the same install block at the top of this README. It wipes the prior source clone and rebuilds from the latest remote — the running app and old `/Applications/Ribbind.app` are replaced in one shot.

---

## Uninstall

1. Quit Ribbind from the menu bar.
2. `rm -rf /Applications/Ribbind.app`
3. *(Optional)* `rm -rf ~/Downloads/ribbind` and revoke Accessibility / Automation in System Settings.

---

## License

[MIT](./LICENSE)
