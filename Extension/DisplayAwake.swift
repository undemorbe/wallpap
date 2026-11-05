import Foundation
import IOKit.pwr_mgt

/// Keeps the display lit while a video wallpaper plays on the lock screen.
///
/// When the Mac is locked, macOS dims the screen after a few seconds and turns it off
/// shortly after, regardless of the "Turn display off" setting. A
/// `PreventUserIdleDisplaySleep` assertion (the same one `caffeinate -d` takes) stops that.
/// It is held only while some wallpaper is animating in the "locked" presentation mode,
/// for at most `lockScreenAwakeMinutes` since the screen was locked, and is released as
/// soon as the Mac is unlocked, playback pauses or the time is up.
@MainActor
enum DisplayAwake {
    private static var playing = Set<ObjectIdentifier>()
    private static var lockedSince: Date?
    private static var assertion: IOPMAssertionID = 0

    /// Reports one wallpaper's state; called on every playback-state evaluation (~every 2 s),
    /// which also lets the time limit expire.
    static func set(_ owner: AnyObject, playingOnLockScreen: Bool, minutes: Int) {
        let id = ObjectIdentifier(owner)
        if playingOnLockScreen { playing.insert(id) } else { playing.remove(id) }

        guard !playing.isEmpty else {
            lockedSince = nil
            release()
            return
        }
        let since = lockedSince ?? Date()
        lockedSince = since
        let withinLimit = minutes < 0 || (minutes > 0 && Date().timeIntervalSince(since) < Double(minutes) * 60)
        if withinLimit { acquire() } else { release() }
    }

    private static func acquire() {
        guard assertion == 0 else { return }
        let reason = "Wallpap: video wallpaper on the lock screen" as CFString
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
        if result == kIOReturnSuccess {
            ExtLog.write("display-awake assertion acquired (\(assertion))")
        } else {
            assertion = 0
            ExtLog.write("display-awake assertion failed: \(String(result, radix: 16))")
        }
    }

    private static func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        ExtLog.write("display-awake assertion released (\(assertion))")
        assertion = 0
    }
}
