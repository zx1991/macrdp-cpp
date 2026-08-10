#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

func boolText(_ value: Bool) -> String {
    value ? "true" : "false"
}

func sessionBoolText(
    _ session: [String: Any],
    _ key: String,
    missingValue: String = "unknown") -> String {
    if let value = session[key] as? Bool {
        return boolText(value)
    }
    if let value = session[key] as? NSNumber {
        return boolText(value.boolValue)
    }
    return missingValue
}

let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("session_on_console=\(sessionBoolText(session, "kCGSSessionOnConsoleKey"))")
print("session_login_done=\(sessionBoolText(session, "kCGSessionLoginDoneKey"))")
let unlockedValue = session.isEmpty ? "unknown" : "false"
let sessionLocked = sessionBoolText(
    session,
    "CGSSessionScreenIsLocked",
    missingValue: unlockedValue)
print("session_locked=\(sessionLocked)")

let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
print(String(format: "modifier_flags=0x%016llx", modifierFlags.rawValue))
print("caps_lock_active=\(boolText(modifierFlags.contains(.capsLock)))")

let modifierKeys: [(String, CGKeyCode)] = [
    ("right_command", 54),
    ("left_command", 55),
    ("left_shift", 56),
    ("caps_lock", 57),
    ("left_option", 58),
    ("left_control", 59),
    ("right_shift", 60),
    ("right_option", 61),
    ("right_control", 62),
    ("fn", 63),
]
for (name, keyCode) in modifierKeys {
    let pressed = CGEventSource.keyState(.combinedSessionState, key: keyCode)
    print("key_\(name)_down=\(boolText(pressed))")
}

let mainDisplay = CGMainDisplayID()
print("main_display_active=\(boolText(CGDisplayIsActive(mainDisplay) != 0))")
print("main_display_asleep=\(boolText(CGDisplayIsAsleep(mainDisplay) != 0))")
print("main_display_online=\(boolText(CGDisplayIsOnline(mainDisplay) != 0))")

var displayCount: UInt32 = 0
let countStatus = CGGetActiveDisplayList(0, nil, &displayCount)
print("display_query_status=\(countStatus.rawValue)")
print("active_display_count=\(displayCount)")

if countStatus == .success && displayCount > 0 {
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    var returnedCount = displayCount
    let displayStatus = CGGetActiveDisplayList(
        displayCount,
        &displays,
        &returnedCount)
    print("display_list_status=\(displayStatus.rawValue)")
    print("returned_display_count=\(returnedCount)")
    if displayStatus == .success {
        for (index, display) in displays.prefix(Int(returnedCount)).enumerated() {
            let bounds = CGDisplayBounds(display)
            let pixelsWide = CGDisplayPixelsWide(display)
            let pixelsHigh = CGDisplayPixelsHigh(display)
            let scale = bounds.width > 0 ? Double(pixelsWide) / bounds.width : 0
            print("display_\(index)_main=\(boolText(CGDisplayIsMain(display) != 0))")
            print("display_\(index)_active=\(boolText(CGDisplayIsActive(display) != 0))")
            print("display_\(index)_asleep=\(boolText(CGDisplayIsAsleep(display) != 0))")
            print("display_\(index)_online=\(boolText(CGDisplayIsOnline(display) != 0))")
            print("display_\(index)_logical_width=\(Int(bounds.width))")
            print("display_\(index)_logical_height=\(Int(bounds.height))")
            print("display_\(index)_pixel_width=\(pixelsWide)")
            print("display_\(index)_pixel_height=\(pixelsHigh)")
            print(String(format: "display_%d_scale=%.2f", index, scale))
            print(String(format: "display_%d_rotation=%.0f", index, CGDisplayRotation(display)))
        }
    }
}
