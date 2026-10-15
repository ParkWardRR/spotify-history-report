package spotify_report

// Nord palette (https://www.nordtheme.com).
//
// `ansi` is the slot the official Nord Terminal.app theme
// (github.com/nordtheme/terminal-app) assigns to that color:
//
//   black=nord1  red=nord11  green=nord14  yellow=nord13
//   blue=nord9   magenta=nord15  cyan=nord8  white=nord5
//   bright black=nord3  bright cyan=nord7  bright white=nord6
//
// On terminals without truecolor (Terminal.app is one) we emit plain ANSI
// codes and let the installed theme do the painting. Colors with no slot
// (nord10, nord12, ...) use ansi = ANSI_NONE and fall back to xterm-256.
Nord :: struct {
	r, g, b: u8,
	ansi:    i8,
}

ANSI_NONE    :: -1 // no theme slot, quantize to xterm-256
ANSI_DEFAULT :: -2 // terminal default fg/bg

// Polar Night
NORD0  :: Nord{0x2E, 0x34, 0x40, ANSI_DEFAULT}
NORD1  :: Nord{0x3B, 0x42, 0x52, 0}
NORD2  :: Nord{0x43, 0x4C, 0x5E, 8}
NORD3  :: Nord{0x4C, 0x56, 0x6A, 8}

// Snow Storm
NORD4  :: Nord{0xD8, 0xDE, 0xE9, ANSI_DEFAULT}
NORD5  :: Nord{0xE5, 0xE9, 0xF0, 7}
NORD6  :: Nord{0xEC, 0xEF, 0xF4, 15}

// Frost
NORD7  :: Nord{0x8F, 0xBC, 0xBB, 14}
NORD8  :: Nord{0x88, 0xC0, 0xD0, 6}
NORD9  :: Nord{0x81, 0xA1, 0xC1, 4}
NORD10 :: Nord{0x5E, 0x81, 0xAC, ANSI_NONE}

// Aurora
NORD11 :: Nord{0xBF, 0x61, 0x6A, 1}
NORD12 :: Nord{0xD0, 0x87, 0x70, ANSI_NONE}
NORD13 :: Nord{0xEB, 0xCB, 0x8B, 3}
NORD14 :: Nord{0xA3, 0xBE, 0x8C, 2}
NORD15 :: Nord{0xB4, 0x8E, 0xAD, 5}

// Comment color from the Nord style guide: nord3 lightened for legible
// secondary text. Shares nord3's bright-black slot in ANSI mode.
NORD_MUTED :: Nord{0x61, 0x6E, 0x88, 8}

// Semantic roles used by the TUI.
COL_TEXT    :: NORD4
COL_BRIGHT  :: NORD6
COL_MUTED   :: NORD_MUTED
COL_FAINT   :: NORD3
COL_ACCENT  :: NORD8
COL_ACCENT2 :: NORD9
COL_OK      :: NORD14
COL_WARN    :: NORD13
COL_ERR     :: NORD11
COL_SURFACE :: NORD1

// Dark foreground for text on bright badges. In ANSI mode this is the theme's
// "black" slot (nord1); NORD0 would map to the terminal default (light) fg.
COL_ON_ACCENT :: Nord{0x2E, 0x34, 0x40, 0}

// Categorical series colors, in a fixed order (genres, bars, legends).
SERIES_COLORS := [?]Nord{NORD8, NORD14, NORD13, NORD12, NORD15, NORD9, NORD7, NORD11, NORD10}
