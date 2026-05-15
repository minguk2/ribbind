# Ribbind

🌐 **English** · [한국어](./README.ko.md)

Bind any keyboard shortcut to any Microsoft Word, PowerPoint, or Google Chrome command on macOS — including Ribbon-only buttons that System Settings can't reach. Currently **v0.6.4**.

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## Install

**1. Download Ribbind.app** from the [latest release](https://github.com/minguk2/ribbind/releases/latest) — grab `Ribbind-v0.6.4.zip`.

**2. Double-click the .zip** to unpack. You'll get `Ribbind.app`.

**3. Drag `Ribbind.app` into `/Applications`.**

**4. First launch only:** right-click `Ribbind.app` in `/Applications` → **Open** → click **Open Anyway**.

This is a one-time Gatekeeper bypass — Ribbind is ad-hoc signed (free; no paid Apple Developer account), so macOS asks for confirmation on the first run only. After this, double-clicking launches Ribbind normally like any other app.

Ribbind lives in the menu bar (no Dock icon). Open Settings from the menu bar icon, or `⌘,`.

**5. First-run permissions** — single click each, when system dialogs prompt:
- **Accessibility** (on first hotkey use): captures shortcuts before Word / PowerPoint / Chrome see them.
- **Automation** (Word / PowerPoint / Chrome): applies the bound effect via Apple Events. Prompts once per app on the first shortcut you fire for it.

### Update

Download the new release zip, drag the new `Ribbind.app` into `/Applications` (replace the old one), and right-click → Open it once. Your shortcuts, picker values, and Accessibility grant carry over automatically.

After replacing the app, you may need to remove and re-add Ribbind in System Settings → Privacy & Security → Accessibility (the code signature rotates per release).

---

## Build from source (optional)

If you'd rather build locally instead of downloading: open Terminal, install Apple's free Command Line Tools (`xcode-select --install`), then run:

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

Same block works for first install and updates. Build is ~30 s. After updates, re-grant Accessibility (rebuilds rotate the signature).

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

**Shortcut does nothing?** Check (1) the target app is foreground, (2) Accessibility is granted to the *current* `/Applications/Ribbind.app` (each release rotates the signature — re-add Ribbind in System Settings → Accessibility), (3) PowerPoint menu shortcuts only register at launch — quit and reopen.

**macOS says "Ribbind cannot be opened because Apple cannot check it"?** That's Gatekeeper on the very first launch. Right-click `Ribbind.app` in Finder → **Open** → **Open Anyway**. macOS remembers your choice; double-click works normally after this.

**Chrome ⌃⌘T does nothing or shows a notification?** Both setup gates must be green in Settings → Google Chrome. Click *Initialize* and follow the prompt for the first model download. On a large page the first press can take a few seconds to translate — wait for the page to settle before pressing again. Press too soon and you'll see a *Translation in progress* notification (the next press is held back so the toggle state stays consistent).

**Notification says "Couldn't detect page language"?** The page has no `<html lang>` attribute and Chrome's `LanguageDetector` API didn't return a result. Reload the tab or pick one with normal HTML.

**Apple Developer account needed?** No. The release `.app` is ad-hoc signed (free, no paid account). The one trade-off is the first-launch *right-click → Open* step above.

**Internet?** Only Chrome's one-time model download. Translation runs on-device after that. No telemetry, no auto-update.

**Will it conflict with my Word customizations?** No — Ribbind writes to the same files Word's *Customize Keyboard* uses. Most-recent assignment wins on collision.

**Update?** Two paths. (1) Download the newer release zip, drag the new `Ribbind.app` into `/Applications` (replacing the old one), and right-click → Open it once. (2) Or rerun the *Build from source* block above — it pulls the latest remote and replaces the installed app in one shot. Either way, your shortcut bindings and picker values carry over.

---

## Uninstall

1. Quit Ribbind from the menu bar.
2. `rm -rf /Applications/Ribbind.app`
3. *(Optional)* `rm -rf ~/Downloads/ribbind` and revoke Accessibility / Automation in System Settings.

---

## License

[MIT](./LICENSE)
