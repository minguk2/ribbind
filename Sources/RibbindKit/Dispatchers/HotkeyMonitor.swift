import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Event-tap based hotkey monitor. Sits at `kCGSessionEventTap, headInsertEventTap` so
/// it intercepts keystrokes BEFORE the frontmost app's responder chain. This is the
/// priority model the user asked for: when Ribbind is running, its bindings
/// win over Word/PowerPoint's own built-in shortcuts for the same combo — because we
/// suppress the event (return nil from the tap callback) and route to the dispatch
/// coordinator ourselves.
///
/// Carbon `RegisterEventHotKey` (the default path used by KeyboardShortcuts) fires
/// AFTER the frontmost app's responder chain has had a chance to consume the key, so
/// Word's internal ⌘1 → CopyFormat binding wins against it in practice. CGEventTap
/// runs before that chain, which fixes the priority question and also has the side
/// benefit of accepting synthetic `CGEventPost` events — a boon for autonomous tests.
public final class HotkeyMonitor {
    public static let shared = HotkeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Multi-valued on purpose: the same combo (e.g. ⌘1) can be bound to different
    // commands in Word AND PowerPoint, and the tap chooses at fire time based on
    // whichever app is frontmost.
    private var bindings: [Combo: [Command]] = [:]
    private var lastFire: [String: CFAbsoluteTime] = [:]
    private var lastWaitingLog: CFAbsoluteTime = 0

    private init() {}

    public struct Combo: Hashable, Sendable {
        public let keyCode: Int64
        public let command: Bool
        public let shift: Bool
        public let option: Bool
        public let control: Bool

        public init(keyCode: Int64, command: Bool, shift: Bool, option: Bool, control: Bool) {
            self.keyCode = keyCode
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }

        public static func fromFlags(_ flags: CGEventFlags, keyCode: Int64) -> Combo {
            Combo(
                keyCode: keyCode,
                command: flags.contains(.maskCommand),
                shift:   flags.contains(.maskShift),
                option:  flags.contains(.maskAlternate),
                control: flags.contains(.maskControl)
            )
        }

        /// Build a Combo from Carbon key code + NSEvent.ModifierFlags-raw style bits
        /// the way `ShortcutBinding` stores them (so we can drive the monitor from the
        /// same persisted state the Recorder produces).
        public static func fromShortcutBinding(macKeyCode: UInt16, modifierMask: UInt32) -> Combo {
            Combo(
                keyCode: Int64(macKeyCode),
                command: modifierMask & 0x100000 != 0,
                shift:   modifierMask & 0x020000 != 0,
                option:  modifierMask & 0x080000 != 0,
                control: modifierMask & 0x040000 != 0
            )
        }
    }

    /// Replace the set of tracked bindings. Call every time the user records / removes
    /// a combo; the next keystroke picks up the new set.
    @MainActor
    public func updateBindings(_ map: [Combo: [Command]]) {
        self.bindings = map
        let totalCommands = map.values.reduce(0) { $0 + $1.count }
        NSLog("[Ribbind] HotkeyMonitor: tracking %d combo(s) covering %d command(s)",
              map.count, totalCommands)
    }

    @MainActor
    public func start() {
        attempt()
        // If Accessibility isn't granted yet, poll every 2 s and auto-start the moment
        // the user toggles the permission on in System Settings. Keeps going until
        // success — no need to restart the app.
        scheduleRetryIfNeeded()
    }

    @MainActor
    private func attempt() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Throttle the "waiting" log: emit at most one line per 30 s so the log
            // isn't flooded while the user is in System Settings toggling the grant.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastWaitingLog > 30 {
                NSLog("[Ribbind] HotkeyMonitor: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility → Ribbind)")
                lastWaitingLog = now
            }
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Ribbind] HotkeyMonitor: CGEvent.tapCreate returned nil even though AX is trusted — will retry")
            return
        }
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source
        NSLog("[Ribbind] HotkeyMonitor: CGEventTap started (tracking %d binding(s))", bindings.count)
    }

    @MainActor
    private func scheduleRetryIfNeeded() {
        guard eventTap == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor in
                guard let self, self.eventTap == nil else { return }
                self.attempt()
                self.scheduleRetryIfNeeded()
            }
        }
    }

    @MainActor
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // macOS may disable a tap if it times out. Re-enable gracefully.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let combo = Combo.fromFlags(event.flags, keyCode: keyCode)

        guard let candidates = monitor.bindings[combo], !candidates.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        // Pick the first candidate whose target app is frontmost. Two Office apps can
        // share the same combo (e.g. ⌘1 → Format Painter in Word AND in PowerPoint),
        // and we route based on focus.
        guard let command = candidates.first(where: { OfficeAppProbe.isFrontmost($0.app) }) else {
            // Neither Word nor PowerPoint is frontmost — let the event pass through so
            // the user can bind the same combo they use in Finder / Xcode / etc.
            return Unmanaged.passUnretained(event)
        }

        // Simple dedupe: if the same command fired within 150 ms, don't fire again.
        // Defense-in-depth — the Carbon `RegisterEventHotKey` path is now disabled
        // (see `BindingCoordinator`'s `.shortcutByNameDidChange` observer), so there's
        // no parallel firer in normal operation. Kept as cheap insurance against a
        // future change re-introducing one.
        let now = CFAbsoluteTimeGetCurrent()
        if let last = monitor.lastFire[command.id], now - last < 0.15 {
            return nil
        }
        monitor.lastFire[command.id] = now

        NSLog("[Ribbind] HotkeyMonitor: captured %@ for %@ — dispatching",
              String(describing: combo), command.id)

        // Dispatch on main actor. CGEventTap callback runs on an arbitrary thread.
        let captured = command
        DispatchQueue.main.async {
            BindingCoordinator.dispatchNow(command: captured)
        }
        return nil // suppress — Word/PowerPoint never see the keystroke
    }
}
