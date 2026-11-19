import Foundation

/// SDL's names for keys (SDL_GetScancodeName), which keybinds.ini uses. SDL names a key by where it
/// sits on a US keyboard, as macOS's virtual key codes do, so a key code maps to one name on any layout.
public enum SDLKeyName {
    /// The SDL name for a Mac virtual key code (NSEvent.keyCode), or nil for a key SDL can't name.
    public static func name(macKeyCode code: UInt16) -> String? { table[code] }

    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 57: "CapsLock",
        56: "Left Shift", 60: "Right Shift", 59: "Left Ctrl", 62: "Right Ctrl",
        58: "Left Alt", 61: "Right Alt", 55: "Left GUI", 54: "Right GUI",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        114: "Insert", 115: "Home", 116: "PageUp", 117: "Delete", 119: "End", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =", 71: "Numlock",
    ]

    /// The modifier keys, which macOS reports as flag changes rather than key presses.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]
}
