import SwiftUI

extension View {
    /// Tapping anywhere on this view dismisses the keyboard. Real,
    /// reported need: a plain `TextField` with no keyboard toolbar and
    /// no "Cancel" button (unlike `.searchable`, which already gets one
    /// for free) left no way to get the keyboard out of the way once it
    /// covered the tab bar — tapping a button/row still works normally
    /// first; this only fires for a tap that lands on empty background.
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
