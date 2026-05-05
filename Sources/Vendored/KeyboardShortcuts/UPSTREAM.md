# Vendored KeyboardShortcuts — Upstream Reference

- **Upstream:** https://github.com/sindresorhus/KeyboardShortcuts
- **Version:** 2.4.0
- **License:** MIT (see `LICENSE` in this directory)
- **Vendored on:** 2026-04-19

## Local modifications

Only these modifications were applied vs. the clean upstream 2.4.0 source tree:

1. **`Recorder.swift` lines 172-185**: three consecutive `#Preview { ... }` blocks removed. Rationale: the `#Preview` macro requires the `PreviewsMacros` plugin that ships with full Xcode only, not with the Command Line Tools toolchain. Removing the blocks lets `swift build` succeed in CLT-only environments (CI or local dev without Xcode). The removal is annotated with a comment in place.

No other changes — no renames, no added imports, no altered behavior. Localization `.lproj` directories preserved as-is.

## Resyncing from upstream

```bash
git clone --depth 1 --branch 2.4.0 https://github.com/sindresorhus/KeyboardShortcuts /tmp/ks-upstream
diff -r Sources/Vendored/KeyboardShortcuts /tmp/ks-upstream/Sources/KeyboardShortcuts
```

The diff should be limited to the three `#Preview` blocks in `Recorder.swift`.
