import Foundation

/// Info.plist keys that make macOS treat an installed iOS game (and the host
/// bundle of a 32-bit game) as a game.
///
/// macOS Game Mode turns on by itself when an app that declares the games
/// category is in full screen: the game gets priority on the CPU and GPU,
/// background work is throttled and Bluetooth controller/headset latency is
/// halved. iOS apps never declare `LSApplicationCategoryType`, so without
/// these keys Game Mode never engaged for them.
///
/// The keys are always written. The per-app Game Mode setting controls the
/// runtime tuning (`PEAR_GAME_MODE`): changing the bundle would require
/// re-signing it on every toggle.
enum GameModeInfo {
    static let gamesCategory = "public.app-category.games"

    static func apply(to info: inout [String: Any]) {
        let category = info["LSApplicationCategoryType"] as? String
        if category == nil || category?.isEmpty == true {
            info["LSApplicationCategoryType"] = gamesCategory
        }
        // Explicit opt-in (macOS 14+); an explicit opt-out by the app is kept.
        if info["LSSupportsGameMode"] == nil { info["LSSupportsGameMode"] = true }
        if info["GCSupportsGameMode"] == nil { info["GCSupportsGameMode"] = true }
        // iPhone-idiom apps are capped at 60 Hz unless they opt out; on a
        // ProMotion Mac the display link then misses every other refresh and
        // frame pacing turns uneven.
        if info["CADisableMinimumFrameDurationOnPhone"] == nil {
            info["CADisableMinimumFrameDurationOnPhone"] = true
        }
        // A game must not be napped when its window is partly covered.
        info["LSAppNapIsDisabled"] = true
        info["NSSupportsAutomaticTermination"] = false
        info["NSSupportsSuddenTermination"] = false
    }
}
