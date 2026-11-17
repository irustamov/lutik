# Accessibility

Lutik uses stock Apple controls (SwiftUI, AppKit and UIKit) and no custom-drawn controls, colors or fonts (see [PRODUCT.md](PRODUCT.md)). Most accessibility behavior therefore comes from the system rather than from code in this repository.

## What to expect

- **VoiceOver.** Toolbar buttons and the comment fields carry explicit labels. On the Mac, the progress bar also carries a label, and archive rows are read as name, size, kind and date; on iPhone and iPad rows are read as name and size or item count. A size that is not known is read as "Unknown size". Decorative images are hidden from VoiceOver.
- **Keyboard.** The Mac app has a standard main menu (File, Edit, View, Window, Help) with the usual shortcuts, and its archive list is a standard table. Dialogs take Return for the default button and Escape for Cancel. On iPad the same default and cancel keys work with a hardware keyboard.
- **Dynamic Type (iOS, iPadOS).** Text uses the system text styles, so it follows the size you choose in Settings.
- **Reduce Motion, Increase Contrast, Reduce Transparency, light and dark appearance.** Followed automatically through the system components. The short intro animation in the iPhone and iPad launch header is skipped when Reduce Motion is on.

## Not yet verified

Lutik has not been formally audited for accessibility, and no assistive-technology user has reviewed it. The goals are the ones in the accessibility section of [PRODUCT.md](PRODUCT.md) ("Accessibility & Inclusion"), and we have not recorded a complete check against them, so treat everything above as intent, not a guarantee. In particular:

- VoiceOver wording and focus order on the Mac and on iPad have not been checked screen by screen.
- The progress bar on iPhone and iPad has no explicit VoiceOver label yet; its title is read as a separate element.
- Large Dynamic Type sizes on iOS may clip in some sheets.
- Other assistive features, such as Voice Control and Switch Control, have not been tested.
- The interface is English only for now, so VoiceOver reads English labels.

## Reporting a problem

If something does not work with VoiceOver, the keyboard, large text or another assistive feature, please open an issue using the bug report form and mention the assistive feature in the steps. Accessibility problems are treated as bugs.
