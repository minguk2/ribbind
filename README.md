# Ribbind

🌐 **English** · [한국어](./README.ko.md)

**Bind any keyboard shortcut to any Microsoft Word, Microsoft PowerPoint, or Google Chrome command on macOS** — including the Ribbon-only ones (Format Painter's paintbrush, shape gallery, Crop, Font Color, …) that macOS's built-in keyboard customizer can't reach, plus Chrome's built-in **Translate Page** as a single-keystroke toggle.

> ☕ **The app is free**, but I'd welcome it if you want to help out this graduate student.
>
> [![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/minguk2)

---

## Install

Build from Terminal. Copy-paste each block below; no developer experience needed.

**1. Open Terminal.** Press `⌘ + Space`, type **Terminal**, hit Enter.

**2. Install Apple's Command Line Tools** (one-time, free, Apple-official):

```sh
xcode-select --install
```

A dialog appears; click **Install**, accept the license, wait a few minutes. *(Already installed? You'll see "command line tools are already installed"; skip to step 3.)*

**3. Download, build, and install Ribbind.** Paste this whole block at once:

```sh
cd ~/Downloads
git clone https://github.com/minguk2/ribbind.git
cd ribbind
scripts/build-app.sh release
pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1
rm -rf /Applications/Ribbind.app
mv dist/Ribbind.app /Applications/
open /Applications/Ribbind.app
```

Build takes ~30 seconds. Ribbind appears in the menu bar (top-right of your screen); no Dock icon by design.

**4. Grant permissions when prompted.**

- **Accessibility** (first launch). Click *Open System Settings* in the prompt, toggle Ribbind on. *(Missed it? System Settings → Privacy & Security → Accessibility → enable Ribbind.)*
- **Automation** (first color or shape shortcut). macOS asks *"Ribbind would like to control Microsoft Word/PowerPoint"*; click **OK**. Once per Office app, then silent forever.

Open Settings from the menu bar icon, or press `⌘,` to start binding shortcuts.

---

## What you can bind

### PowerPoint

![PowerPoint settings tab](docs/screenshots/settings-powerpoint.png)

- **Format:** Format Painter, Font Color 1/2/3 (per-binding RGB picker), Font Family
- **Picture:** Crop, Lock Aspect Ratio
- **Shapes:** Text Box (lands at cursor), Oval, Rectangle, Rounded Rectangle, Down Arrow, Left Arrow
- **Slide Show:** Hide Slide

The four menu-accessible shapes (Text Box / Oval / Rectangle / Rounded Rectangle) dispatch via PowerPoint's native menu, so the shortcut **arms the drag-to-create cursor** — exactly like clicking the Insert menu by hand. The block arrows insert a fixed-size shape at the cursor's slide position.

### Word

![Word settings tab](docs/screenshots/settings-word.png)

- **Format:** Format Painter, Highlight 1/2/3 (per-binding named color: yellow / bright green / blue / pink / red / etc.), Font Color 1/2/3 (RGB picker), Font Family
- **Picture:** Crop, Lock Aspect Ratio

Highlights write Word's native `<w:highlight>` element, so the **No Color button in the Home ribbon clears them normally** — no more "I can only undo with Format Painter".

### Google Chrome

![Google Chrome settings tab](docs/screenshots/settings-chrome.png)

- **Translate Page (toggle)** — pick any of 18 target languages (Korean, Japanese, Chinese Simp/Trad, Spanish, French, German, Italian, Portuguese, Russian, Arabic, Hindi, Vietnamese, Thai, Indonesian, Turkish, Dutch, Polish). Press the shortcut once → page text translates in place via Chrome's built-in on-device Translator API. Press again → originals restored. No cursor movement, no menu flicker, no external network at translation time, no API keys, no rate limits.

Two one-time setups guided in the Chrome tab itself:
1. Toggle *Chrome > View > Developer > Allow JavaScript from Apple Events* (Chrome's per-profile security gate)
2. Click "Initialize translation model" in Ribbind, then click anywhere on a Chrome page once. Chrome downloads the on-device model for your chosen language pair (~50 MB, one-time per pair).

### Per-binding parameter pickers

Highlight rows show a **named-color swatch**, Font Color rows show an **RGB color well**, Font Family rows show a **system font picker**, and Translate rows show a **target-language menu** — each remembered per binding and persisted across export/import.

Orange ⚠ next to *Crop* / *Lock Aspect Ratio* means **a selection is required** (those commands act on whatever picture is currently selected).

**Don't see what you need?** Click *Add from Word…* or *Add from PowerPoint…* in the toolbar; Ribbind reads any Ribbon button or menu item directly from your installed Office. No restart needed.

**Want a feature beyond binding existing commands?** **[Open an issue](../../issues/new)** and tell me. I read every one.

---

## Permissions and the General tab

![General settings tab](docs/screenshots/settings-general.png)

Three macOS permissions, each prompted once on demand:

| Permission | When | Why |
|---|---|---|
| **Accessibility** | First launch | Catch your shortcut before Office / Chrome sees it; click Ribbon buttons on your behalf. |
| **Automation** (Word / PowerPoint) | First Word/PPT color or shape shortcut | Tell Office to apply formatting or insert the shape directly. |
| **Automation** (Google Chrome) | First Translate Page shortcut | Run translation JavaScript in Chrome's active tab. |

Plus one Chrome-side toggle (one-time, not a system permission): **Chrome > View > Developer > Allow JavaScript from Apple Events**. Ribbind's Settings → Google Chrome tab walks you through this with a one-click helper.

Revoke later in *System Settings → Privacy & Security → Accessibility / Automation*.

The **General** tab is your setup-at-a-glance:

- **Accessibility:** green check = wired up. Red? Click *Re-grant Accessibility*.
- **Office detection:** confirms Word/PowerPoint found, shows version + path.
- **Launch at login:** start automatically.
- **Import / Export:** JSON round-trip for moving bindings between Macs.

---

## FAQ

**My shortcut does nothing.** Check, in order: (1) Word / PowerPoint / Chrome is the foreground window, (2) Accessibility is granted to the *current* `/Applications/Ribbind.app` (rebuilds rotate the code-signature, so after every update you may need to remove and re-add Ribbind in *System Settings → Privacy & Security → Accessibility*), (3) PowerPoint menu-item shortcuts only register on launch, so quit and reopen PowerPoint after binding.

**My Chrome ⌃⌘T does nothing / shows a notification.** The Translate Page command needs *Chrome > View > Developer > Allow JavaScript from Apple Events* enabled (one-time per Chrome profile), plus a one-time on-device model download for the language pair you picked. Ribbind's Settings → Google Chrome tab guides both: green ✓ rows mean ready, orange ⚠ means action needed.

**Apple Developer account ($99/yr) needed?** No. Ribbind is open-source and you build it with Apple's free Command Line Tools; that's why the install is a Terminal copy-paste, not a downloaded `.zip`.

**Does it talk to the internet?** No, after the one-time Chrome translation-model download. The download itself is a Chrome operation (Chrome contacts Google's model server). All other Ribbind operations are 100% local: no telemetry, no auto-update, no analytics. Translation at runtime uses Chrome's on-device model, not a network call.

**Will it conflict with my existing Word customizations?** No. Ribbind writes to the same place Word/PowerPoint already use (the files Word's *Customize Keyboard* dialog and PowerPoint's menu shortcuts touch). Existing bindings stay; if a combo collides, the most recent assignment wins.

**Update to a newer version?** Run this:

```sh
cd ~/Downloads/ribbind && git pull && scripts/build-app.sh release && \
  pkill -f /Applications/Ribbind.app 2>/dev/null; sleep 1 && \
  rm -rf /Applications/Ribbind.app && \
  mv dist/Ribbind.app /Applications/ && open /Applications/Ribbind.app
```

(May need to re-grant Accessibility after; see the first FAQ.)

---

## Uninstall

1. Quit Ribbind from the menu bar (icon → *Quit*).
2. `rm -rf /Applications/Ribbind.app` (or move it to Trash).
3. *(Optional)* `rm -rf ~/Downloads/ribbind` to remove the source.
4. *(Optional)* Revoke Accessibility / Automation in *System Settings → Privacy & Security*.

---

## License & support

[MIT](./LICENSE). Vendored [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) retains its own MIT (see [`Sources/Vendored/KeyboardShortcuts/LICENSE`](./Sources/Vendored/KeyboardShortcuts/LICENSE)).

If Ribbind saved you time and you'd like to send a coffee, [here's the link](https://ko-fi.com/minguk2). It really does help.
