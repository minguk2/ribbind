# Ribbind

🌐 **English** · [한국어](./README.ko.md)

Bind any keyboard shortcut to any Microsoft Word, PowerPoint, or Google Chrome command on macOS — including Ribbon-only buttons that System Settings can't reach. Currently **v0.6.5**.

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## Install

**1. Download the installer** from the [latest release](https://github.com/minguk2/ribbind/releases/latest) — grab `Ribbind-v0.6.5.dmg`.

**2. Double-click the DMG.** A window opens with `Ribbind.app` and a shortcut to **Applications**.

**3. Drag `Ribbind.app` onto the Applications shortcut.** Installed.

Eject the DMG from Finder's sidebar afterward (right-click → Eject).

### First launch (one-time Gatekeeper bypass)

Ribbind is ad-hoc signed — free, no paid Apple Developer account, so macOS asks you to confirm the first run:

1. In Finder, open `/Applications` and **double-click `Ribbind.app`**.
2. macOS shows: *"Ribbind" cannot be opened because Apple cannot check it for malicious software.* — click **Done**.
3. Open **System Settings → Privacy & Security**.
4. Scroll down to find: *"Ribbind" was blocked to protect your Mac.* — click **Open Anyway** next to it.
5. Authenticate (Touch ID or password), then confirm **Open**.

After this once, double-clicking `Ribbind.app` works normally. Ribbind lives in the menu bar (no Dock icon). Open Settings from the menu bar icon or `⌘,`.

### First-run permissions

Each is a single click in a system dialog the first time it's needed:

- **Accessibility** — captures global hotkeys before Word / PowerPoint / Chrome see them.
- **Automation** (Word / PowerPoint / Chrome) — applies the bound effect via Apple Events. Prompts once per app on your first shortcut for that app.

### Update

Download the new release DMG, drag the new `Ribbind.app` onto the Applications shortcut (replacing the old one), then repeat the **System Settings → Privacy & Security → Open Anyway** step once for the new release. Your shortcuts, picker values, and Accessibility grant carry over automatically (you may need to remove and re-add Ribbind in System Settings → Privacy & Security → Accessibility — the code signature rotates per release).

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

**macOS says "Ribbind cannot be opened because Apple cannot check it"?** That's Gatekeeper on the very first launch. Click **Done** on that dialog, then go to **System Settings → Privacy & Security**, scroll down to *"Ribbind" was blocked to protect your Mac*, and click **Open Anyway**. Authenticate, then confirm Open. macOS remembers your choice; double-click works normally after this. (On macOS Sequoia 15+ this is the only path — Apple removed the older right-click → Open shortcut from the Finder context menu.)

**Chrome ⌃⌘T does nothing or shows a notification?** Both setup gates must be green in Settings → Google Chrome. Click *Initialize* and follow the prompt for the first model download. On a large page the first press can take a few seconds to translate — wait for the page to settle before pressing again. Press too soon and you'll see a *Translation in progress* notification (the next press is held back so the toggle state stays consistent).

**Notification says "Couldn't detect page language"?** The page has no `<html lang>` attribute and Chrome's `LanguageDetector` API didn't return a result. Reload the tab or pick one with normal HTML.

**Apple Developer account needed?** No. The release `.app` is ad-hoc signed (free, no paid account). The trade-off is the first-launch *System Settings → Privacy & Security → Open Anyway* step above.

**Internet?** Only Chrome's one-time model download. Translation runs on-device after that. No telemetry, no auto-update.

**Will it conflict with my Word customizations?** No — Ribbind writes to the same files Word's *Customize Keyboard* uses. Most-recent assignment wins on collision.

**Update?** Two paths. (1) Download the newer release DMG, drag the new `Ribbind.app` onto the Applications shortcut (replacing the old one), then repeat the *System Settings → Privacy & Security → Open Anyway* step once for the new release. (2) Or rerun the *Build from source* block above — it pulls the latest remote and replaces the installed app in one shot. Either way, your shortcut bindings and picker values carry over.

---

## Uninstall

1. Quit Ribbind from the menu bar.
2. `rm -rf /Applications/Ribbind.app`
3. *(Optional)* `rm -rf ~/Downloads/ribbind` and revoke Accessibility / Automation in System Settings.

---

## License

[MIT](./LICENSE)
