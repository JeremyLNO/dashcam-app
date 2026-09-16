import SwiftUI

/// The widget's colours, kept apart from the app's `Theme`.
///
/// Two reasons, and the second is the one that bites: the extension does not compile the
/// app's design system, so anything the widget draws with has to live in a file shared with
/// it. And the widget is **dark** while the app is deliberately light — a home screen is
/// seen against a wallpaper at arm's length, not held at reading distance, and the same
/// cream ground that makes the app legible in a car makes a widget shout from the
/// home screen.
enum WidgetPalette {
    /// Recording red: the colour the app already uses for « this is filming », so the
    /// record button on the home screen is the same object as the one in the app.
    static let accent = Color(red: 0.90, green: 0.28, blue: 0.31)
    /// Nothing has been recorded in a while. Orange rather than red: it is a nudge, not an
    /// alarm, and red already means something else here.
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let bar = Color(red: 0.25, green: 0.66, blue: 0.96)
    static let track = Color.white.opacity(0.15)
    static let background = Color(red: 0.055, green: 0.078, blue: 0.125)
    /// What stands in for a frame of road when there is none to show.
    static let stillTop = Color(red: 0.11, green: 0.17, blue: 0.29)
    static let stillBottom = Color(red: 0.04, green: 0.07, blue: 0.13)
}
