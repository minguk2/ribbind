# Agent Rules

## Update Requests

When Minguk asks to "update" Ribbind, treat it as the full release path unless he explicitly narrows the scope.

1. Review code, user-facing docs, screenshots, bundle metadata, and release workflow together.
2. If shipping a new build, bump `CFBundleShortVersionString` in `AppBundleResources/Info.plist` and update matching version/download references in both `README.md` and `README.ko.md`.
3. Refresh outdated README screenshots, especially `docs/screenshots/settings-*.png`, from the current built app UI.
4. Run local verification: `swift build`, `swift run ValidationHarness`, and `scripts/build-app.sh release`.
5. Verify the release packaging path locally where possible: code signature, bundle structure, DMG creation, ZIP creation, and SHA-256 files.
6. Commit only the intended files. Keep author and committer as Minguk's configured git identity; do not add AI/co-author trailers.
7. Push `main`, create and push the next version tag, then monitor the GitHub Actions `Release` workflow to completion.
8. Confirm the GitHub Release exists, is latest, and has all four assets: `.dmg`, `.dmg.sha256`, `.zip`, `.zip.sha256`.
9. Report any local-only limitation separately from release failure. For example, universal local builds require full Xcode, but GitHub Actions must still pass the universal build.
