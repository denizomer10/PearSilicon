import AppKit
import Carbon.HIToolbox
import Foundation

/// Canonical keyboard names shared by the editor and the runtime keymap.
///
/// The runtime keymap uses USB-HID-style names (`space`, `left`, `minus`,
/// `f5`, …), so the editor records physical keys instead of relying on the
/// current keyboard layout's characters. That keeps a binding stable when the
/// user changes input source.
enum KeyNames {

    /// Human-readable label for a stored key name.
    static func display(_ key: String) -> String {
        switch key.lowercased() {
        case "wasd": return "WASD"
        case "mouse": return "MOUSE"
        case "space": return "SPACE"
        case "enter": return "RETURN"
        case "escape": return "ESC"
        case "tab": return "TAB"
        case "backspace": return "⌫"
        case "delete": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "HOME"
        case "end": return "END"
        case "pageup": return "PGUP"
        case "pagedown": return "PGDN"
        case "shift": return "SHIFT"
        case "control": return "CTRL"
        case "option": return "OPT"
        case "command": return "CMD"
        case "capslock": return "CAPS"
        default: return key.uppercased()
        }
    }

    /// Converts an AppKit key event to the canonical name used in the keymap.
    /// Returns nil for events that cannot be mapped (for example a dead key).
    static func canonical(from event: NSEvent) -> String? {
        if let name = physicalName(forKeyCode: Int(event.keyCode)) {
            return name
        }
        guard event.type == .keyDown || event.type == .keyUp else { return nil }

        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else {
            return nil
        }
        let value = raw.lowercased()
        if value == " " { return "space" }
        if value == "\r" || value == "\n" { return "enter" }
        if value == "\t" { return "tab" }
        if value == "\u{1b}" { return "escape" }
        if value == "\u{7f}" { return "backspace" }

        // Shifted punctuation still belongs to the physical key below it.
        switch value {
        case "!": return "1"
        case "@": return "2"
        case "#": return "3"
        case "$": return "4"
        case "%": return "5"
        case "^": return "6"
        case "&": return "7"
        case "*": return "8"
        case "(": return "9"
        case ")": return "0"
        case "_": return "minus"
        case "+": return "equal"
        case "{": return "openbracket"
        case "}": return "closebracket"
        case "|": return "backslash"
        case ":": return "semicolon"
        case "\"": return "quote"
        case "<": return "comma"
        case ">": return "period"
        case "?": return "slash"
        case "~": return "grave"
        default:
            // Letters and digits are already canonical; other layouts may
            // produce a different character, which is stored as-is.
            return value.count == 1 ? value : nil
        }
    }

    /// Physical-key names for the ANSI layout and the special keys. These are
    /// the names the runtime resolves from `GCKeyCode`.
    private static func physicalName(forKeyCode code: Int) -> String? {
        switch code {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"

        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        case kVK_ANSI_Minus: return "minus"
        case kVK_ANSI_Equal: return "equal"
        case kVK_ANSI_LeftBracket: return "openbracket"
        case kVK_ANSI_RightBracket: return "closebracket"
        case kVK_ANSI_Backslash: return "backslash"
        case kVK_ANSI_Semicolon: return "semicolon"
        case kVK_ANSI_Quote: return "quote"
        case kVK_ANSI_Comma: return "comma"
        case kVK_ANSI_Period: return "period"
        case kVK_ANSI_Slash: return "slash"
        case kVK_ANSI_Grave: return "grave"

        case kVK_Return, kVK_ANSI_KeypadEnter: return "enter"
        case kVK_Tab: return "tab"
        case kVK_Space: return "space"
        case kVK_Delete: return "backspace"
        case kVK_ForwardDelete: return "delete"
        case kVK_Escape: return "escape"
        case kVK_LeftArrow: return "left"
        case kVK_RightArrow: return "right"
        case kVK_UpArrow: return "up"
        case kVK_DownArrow: return "down"
        case kVK_Home: return "home"
        case kVK_End: return "end"
        case kVK_PageUp: return "pageup"
        case kVK_PageDown: return "pagedown"
        case kVK_Help: return "insert"

        case kVK_Shift, kVK_RightShift: return "shift"
        case kVK_Control, kVK_RightControl: return "control"
        case kVK_Option, kVK_RightOption: return "option"
        case kVK_Command, kVK_RightCommand: return "command"
        case kVK_CapsLock: return "capslock"
        case kVK_Function: return "fn"

        case kVK_F1: return "f1"
        case kVK_F2: return "f2"
        case kVK_F3: return "f3"
        case kVK_F4: return "f4"
        case kVK_F5: return "f5"
        case kVK_F6: return "f6"
        case kVK_F7: return "f7"
        case kVK_F8: return "f8"
        case kVK_F9: return "f9"
        case kVK_F10: return "f10"
        case kVK_F11: return "f11"
        case kVK_F12: return "f12"
        case kVK_F13: return "f13"
        case kVK_F14: return "f14"
        case kVK_F15: return "f15"
        case kVK_F16: return "f16"
        case kVK_F17: return "f17"
        case kVK_F18: return "f18"
        case kVK_F19: return "f19"
        case kVK_F20: return "f20"

        case kVK_ANSI_Keypad0: return "keypad0"
        case kVK_ANSI_Keypad1: return "keypad1"
        case kVK_ANSI_Keypad2: return "keypad2"
        case kVK_ANSI_Keypad3: return "keypad3"
        case kVK_ANSI_Keypad4: return "keypad4"
        case kVK_ANSI_Keypad5: return "keypad5"
        case kVK_ANSI_Keypad6: return "keypad6"
        case kVK_ANSI_Keypad7: return "keypad7"
        case kVK_ANSI_Keypad8: return "keypad8"
        case kVK_ANSI_Keypad9: return "keypad9"
        case kVK_ANSI_KeypadDecimal: return "keypadperiod"
        case kVK_ANSI_KeypadMultiply: return "keypadasterisk"
        case kVK_ANSI_KeypadPlus: return "keypadplus"
        case kVK_ANSI_KeypadMinus: return "keypadminus"
        case kVK_ANSI_KeypadDivide: return "keypadslash"
        case kVK_ANSI_KeypadEquals: return "keypadequal"
        case kVK_ANSI_KeypadClear: return "keypadclear"

        default: return nil
        }
    }
}
