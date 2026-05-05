import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Maps the global mouse cursor into PowerPoint slide-coordinate space (points).
/// Backs the `{{mouse.slideX}}` / `{{mouse.slideY}}` placeholders in
/// `appleScript`-recipe sources, so a command like "insert text box" places the
/// box where the cursor is rather than at a hardcoded slide coordinate.
///
/// Pipeline:
/// 1. `NSEvent.mouseLocation` (Cocoa, BL origin) → flip Y using the primary
///    display's height so the result lives in AX's TL-origin global coord space.
/// 2. Walk the focused PowerPoint window's AX tree to the slide editing canvas
///    — PPT exposes the canvas as an `AXLayoutArea` whose `AXDescription`
///    starts with "Slide Editor Pane" (verified empirically via
///    `ValidationHarness ppt-enumerate-buttons`). The notes pane is also an
///    `AXLayoutArea` ("Notes Pane") — we filter by description to avoid hitting
///    the wrong one. Fallback: any non-Notes `AXLayoutArea`.
/// 3. Query `slide width` of `page setup of active presentation` via AppleScript.
///    PowerPoint Mac's AS dictionary intentionally omits `slide height` (the
///    only page-setup exposed properties are first-slide-number, slide-size
///    enum, slide-orientation, notes-orientation, slide-width — verified via
///    .sdef inspection and live `properties of page setup` dump). We guess
///    the height from the standard aspect ratios: width ≈ 720pt → 4:3 (h=540);
///    anything else → 16:9 (Office's default since 2013).
/// 4. PowerPoint renders the slide centered in the canvas at the largest scale
///    that preserves aspect ratio (`scale = min(canvasW/slideW, canvasH/slideH)`).
///    Compute the rendered slide rect in screen-pt, then invert:
///    `slideXY = (cursor − renderedRect.origin) / scale`. Clamp to slide bounds
///    so an off-canvas cursor (sidebar / margins) still produces an on-slide
///    insertion point at the nearest edge.
///
/// Returns `nil` if any step fails (PPT not running, AX not granted, canvas not
/// findable, AppleScript denied/failed). The caller in `BindingCoordinator`
/// falls back to a slide-center default so the textbox is always visible.
///
/// Currently scoped to PowerPoint only — Word's text-box insertion has a
/// different geometry model (anchored to a paragraph in the document, not free
/// coordinates on a canvas) and would need a separate mapping strategy.
public enum MouseSlideMapper {
    /// Slide-space (x, y) in points under the current cursor for `targetApp`,
    /// or `nil` if mapping fails. Caller decides the fallback.
    public static func slidePositionUnderMouse(targetApp: AppTarget) -> (x: Double, y: Double)? {
        guard targetApp == .powerpoint else { return nil }
        guard AXIsProcessTrusted() else { return nil }

        let cocoa = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).size.height
        let axCursor = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)

        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.microsoft.Powerpoint"
        ).first else { return nil }
        let appAX = AXUIElementCreateApplication(running.processIdentifier)

        // Walk from app root — PPT's slide canvas isn't always under
        // `kAXFocusedWindowAttribute` (the focused window may be a panel/dialog).
        guard let canvas = findSlideCanvas(in: appAX),
              let canvasFrame = axFrame(of: canvas),
              canvasFrame.size.width > 0,
              canvasFrame.size.height > 0
        else { return nil }

        guard let (slideW, slideH) = querySlideDimensions() else { return nil }

        // PowerPoint renders the slide centered in the canvas at the largest
        // scale that preserves aspect ratio (letterbox / pillarbox). Reverse
        // that transform to map cursor pixels back into slide points.
        let scale = min(canvasFrame.size.width / slideW, canvasFrame.size.height / slideH)
        let renderedW = slideW * scale
        let renderedH = slideH * scale
        let renderedX = canvasFrame.midX - renderedW / 2
        let renderedY = canvasFrame.midY - renderedH / 2

        let slideX = (axCursor.x - renderedX) / scale
        let slideY = (axCursor.y - renderedY) / scale

        let cx = max(0, min(slideW, slideX))
        let cy = max(0, min(slideH, slideY))
        if ProcessInfo.processInfo.environment["RIBBIND_MAPPER_DEBUG"] != nil {
            NSLog("[MouseSlideMapper] cursor=ax(%.0f,%.0f) canvas=(%.0f,%.0f %.0fx%.0f) slide=%.0fx%.0f scale=%.3f rendered=(%.0f,%.0f %.0fx%.0f) raw=(%.0f,%.0f) clamped=(%.0f,%.0f)",
                  axCursor.x, axCursor.y,
                  canvasFrame.origin.x, canvasFrame.origin.y, canvasFrame.size.width, canvasFrame.size.height,
                  slideW, slideH, scale, renderedX, renderedY, renderedW, renderedH,
                  slideX, slideY, cx, cy)
        }
        return (cx, cy)
    }

    private static func findSlideCanvas(in root: AXUIElement) -> AXUIElement? {
        // Preferred match: AXLayoutArea whose description starts with "Slide Editor Pane".
        // Secondary: any other AXLayoutArea (excludes the Notes Pane via description).
        // Tertiary: the largest AXLayoutArea by area.
        var preferred: AXUIElement?
        var anyLayoutArea: (AXUIElement, CGFloat)?

        func walk(_ el: AXUIElement, depth: Int) {
            if preferred != nil { return }
            if depth > 25 { return }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                el, kAXRoleAttribute as CFString, &roleRef
            ) == .success,
               let role = roleRef as? String,
               role == "AXLayoutArea" {
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    el, kAXDescriptionAttribute as CFString, &descRef
                )
                let desc = (descRef as? String) ?? ""
                if desc.hasPrefix("Slide Editor Pane") {
                    preferred = el
                    return
                }
                if !desc.contains("Notes Pane"), let frame = axFrame(of: el) {
                    let area = frame.size.width * frame.size.height
                    if anyLayoutArea == nil || area > anyLayoutArea!.1 {
                        anyLayoutArea = (el, area)
                    }
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                el, kAXChildrenAttribute as CFString, &childrenRef
            ) == .success,
               let children = childrenRef as? [AXUIElement] {
                for c in children {
                    walk(c, depth: depth + 1)
                    if preferred != nil { return }
                }
            }
        }

        walk(root, depth: 0)
        return preferred ?? anyLayoutArea?.0
    }

    private static func axFrame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            el, kAXPositionAttribute as CFString, &posRef
        ) == .success,
              AXUIElementCopyAttributeValue(
                el, kAXSizeAttribute as CFString, &sizeRef
              ) == .success,
              let pos = posRef,
              let size = sizeRef
        else { return nil }

        var origin = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &sz)
        return CGRect(origin: origin, size: sz)
    }

    private static func querySlideDimensions() -> (Double, Double)? {
        // PPT Mac's AS dictionary exposes `slide width` but NOT `slide height` on
        // `page setup` — verified empirically (-1728 on `slide height of ps`, and
        // `properties of ps` returns only PsF#/PsWh/PsSs/PsNo/PsSo). Guess the
        // height from the width: 720pt → 4:3 (h=540), all other widths → 16:9
        // (Office's default since 2013; covers 960pt, 1280pt, etc.).
        let src = """
        tell application "Microsoft PowerPoint"
            set p to active presentation
            return (slide width of page setup of p) as string
        end tell
        """
        do {
            guard let raw = try AppleScriptRunner.run(src) else { return nil }
            guard let w = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            let aspect: Double = (abs(w - 720) < 1) ? (4.0 / 3.0) : (16.0 / 9.0)
            return (w, w / aspect)
        } catch {
            return nil
        }
    }
}
