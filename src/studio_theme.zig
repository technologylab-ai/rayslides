//! Central Studio chrome theme.
//!
//! Studio used to spell its colours out at every call site, which drifted into
//! ~290 near-duplicate literals: nine shades of panel grey, cyan borders on
//! every surface, and magenta/purple accents competing for the same attention.
//! The palette below is the single source of truth for editor chrome so the
//! shell reads like a normal dark desktop application.
//!
//! Rules of the house:
//!
//! * Surfaces are neutral and cool. Elevation is expressed by getting lighter,
//!   never by changing hue.
//! * Borders are quiet. A 1 px `border` separates surfaces; `border_strong` is
//!   reserved for interactive edges the pointer can land on.
//! * There is exactly ONE accent. It means "this is selected, active, or
//!   focused" and nothing else. If two things on screen are accented, one of
//!   them is wrong.
//! * Semantic colours (danger/warning/success) are for state the user must
//!   read, not for decoration.
//!
//! Canvas overlays — snap guides, rulers, measurements, safe areas — are
//! deliberately NOT themed here. They sit on top of user artwork rather than
//! on chrome, so they keep their high-chroma signal colours.

const rl = @import("raylib");

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// Re-alpha an existing theme colour without restating its channels.
pub fn alpha(color: rl.Color, a: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = a };
}

// ---------------------------------------------------------------------------
// Surfaces (ascending elevation)
// ---------------------------------------------------------------------------

/// Behind every dock; the darkest thing in the shell.
pub const backdrop = rgb(0x0A, 0x0C, 0x11);
/// Inputs, previews, and wells punched into a panel.
pub const sunken = rgb(0x0E, 0x11, 0x17);
/// Docked panels: Slides, Library, Objects, Properties, status.
pub const surface = rgb(0x14, 0x18, 0x20);
/// List rows and cards sitting on `surface`.
pub const row = rgb(0x1A, 0x1F, 0x28);
/// Floating instruments: command palette, choosers, pickers.
pub const raised = rgb(0x1C, 0x21, 0x2B);
/// Tooltips and small popovers — the topmost layer.
pub const overlay = rgb(0x22, 0x28, 0x33);
/// Modal scrim dimming the deck behind a floating panel.
pub const scrim = rgba(0x06, 0x08, 0x0D, 0xB4);
/// Drop shadow beneath floating panels.
pub const shadow = rgba(0x00, 0x00, 0x00, 0x66);

// ---------------------------------------------------------------------------
// Borders
// ---------------------------------------------------------------------------

/// Hairline between two surfaces of similar value.
pub const border_subtle = rgb(0x22, 0x28, 0x32);
/// Default panel and card outline.
pub const border = rgb(0x2C, 0x33, 0x3F);
/// Edge of something clickable: buttons, fields, swatches.
pub const border_strong = rgb(0x3B, 0x44, 0x52);

// ---------------------------------------------------------------------------
// Text ramp
// ---------------------------------------------------------------------------

/// Primary labels and values.
pub const text = rgb(0xE7, 0xEB, 0xF2);
/// Supporting copy: descriptions, metadata, units.
pub const text_secondary = rgb(0xA4, 0xAE, 0xBE);
/// De-emphasised: counts, hints, placeholders.
pub const text_muted = rgb(0x78, 0x83, 0x94);
/// Unavailable controls.
pub const text_disabled = rgb(0x59, 0x62, 0x71);
/// Section headings above a panel's contents.
pub const text_heading = rgb(0xC3, 0xCC, 0xDA);

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

/// Button at rest.
pub const control = rgb(0x20, 0x26, 0x30);
/// Button under the pointer.
pub const control_hover = rgb(0x29, 0x30, 0x3C);
/// Button that cannot be used right now.
pub const control_disabled = rgb(0x16, 0x1A, 0x21);
/// Text input / numeric field well.
pub const field = rgb(0x11, 0x15, 0x1C);

// ---------------------------------------------------------------------------
// Accent — selection, activation, focus. Use sparingly.
// ---------------------------------------------------------------------------

/// The accent line/border itself.
pub const accent = rgb(0x3E, 0xA6, 0xDF);
/// Accent text and carets on dark surfaces.
pub const accent_bright = rgb(0x7C, 0xCB, 0xF4);
/// Filled active control (pressed toggle, current tab).
pub const accent_fill = rgb(0x1B, 0x55, 0x7A);
/// Selected row wash — tinted just enough to track down a long list.
pub const accent_soft = rgb(0x16, 0x2F, 0x43);
/// Text selection highlight inside fields.
pub const selection = rgb(0x1F, 0x4B, 0x6B);

// ---------------------------------------------------------------------------
// Semantic state
// ---------------------------------------------------------------------------

pub const danger = rgb(0xE0, 0x5A, 0x5F);
pub const danger_soft = rgb(0x3A, 0x1D, 0x21);
pub const warning = rgb(0xE0, 0xA0, 0x40);
pub const warning_soft = rgb(0x38, 0x2A, 0x14);
pub const success = rgb(0x4C, 0xC0, 0x8A);
pub const info = accent;

/// A local override differs from the inherited/authored value.
pub const override_marker = warning;
pub const override_fill = warning_soft;

// ---------------------------------------------------------------------------
// Library entry kinds — the one place chrome needs categorical colour. Kept
// low-chroma so a list of them still reads as a list, not as confetti.
// ---------------------------------------------------------------------------

pub const kind_element = rgb(0x35, 0x77, 0x99);
pub const kind_group = rgb(0x74, 0x66, 0xA8);
pub const kind_slide = rgb(0x4E, 0x83, 0x74);
