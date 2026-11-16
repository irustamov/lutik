import AppKit

/// Edit > Cut and Copy wherever an archive window's rows aren't the target: the standard cut: /
/// copy: of whatever answers it from the key window's first responder on (a field, an open or save panel, a
/// sheet, the preview, the About panel), found and validated as a stock Edit menu item's target is. The menu
/// items carry `copySelection:` / `cutSelection:` (SwiftUI's `onCopyCommand` empties the pasteboard before a
/// Copy's export ends); the archive window controller answers them, and the app delegate when no archive
/// window is key or main.
struct StandardEditCommand {
    /// The object a nil-targeted `action` from `sender` reaches now, from the key window's first responder on
    /// (`NSApp.target(forAction:to:from:)`). Tests stand in a window's chain: a hosted test's window is never key.
    var target: @MainActor (_ action: Selector, _ sender: Any?) -> AnyObject? = { action, sender in
        NSApp.target(forAction: action, to: nil, from: sender) as AnyObject?
    }

    /// Sends `action` to its target; nothing when none answers it or it is editable text with only the caret
    /// (`isCaretOnlyInEditableText`).
    @MainActor func send(_ action: Selector, from sender: Any?) {
        guard let target = target(action, sender), !Self.isCaretOnlyInEditableText(target) else { return }
        NSApp.sendAction(action, to: target, from: sender)
    }

    /// Whether `action` is enabled: as its target validates it (a menu item's validation first, as AppKit
    /// asks); false when none answers it. A validation counts as AppKit counts it, by what the target responds
    /// to: an informal one (a remote panel's view, the Quick Look preview) declares no conformance. Off at
    /// editable text with only the caret (`isCaretOnlyInEditableText`), whatever the text answers.
    @MainActor func validate(_ action: Selector, for sender: Any?) -> Bool {
        guard let target = target(action, sender), !Self.isCaretOnlyInEditableText(target) else { return false }
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let enabled = Self.call(#selector(NSMenuItemValidation.validateMenuItem(_:)), of: target, with: probe) {
            return enabled
        }
        if let enabled = Self.call(#selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:)), of: target,
                                   with: probe) {
            return enabled
        }
        return true
    }

    /// Whether `focus`, or a view that holds it, is editable text (a field's editor, a text view: a name, the
    /// Info comment, the search) with only the caret: there Edit > Cut and Copy do nothing and are off, in any
    /// window. A text view may enable copy: at a caret, which puts empty text on the pasteboard, and
    /// the rows aren't meant while the user types. Selectable text that isn't editable is not such a focus.
    @MainActor static func isCaretOnlyInEditableText(_ focus: AnyObject?) -> Bool {
        var view = focus as? NSView
        while let current = view {
            if let text = current as? NSText { return text.isEditable && text.selectedRange.length == 0 }
            view = current.superview
        }
        return false
    }

    /// `validation` (a `- (BOOL)validate…:(id)item` method) of `target` on `item`; nil when it doesn't respond to it.
    @MainActor private static func call(_ validation: Selector, of target: AnyObject, with item: NSMenuItem) -> Bool? {
        guard let object = target as? NSObject, object.responds(to: validation) else { return nil }
        typealias Validation = @convention(c) (NSObject, Selector, NSMenuItem) -> ObjCBool
        let method = unsafeBitCast(object.method(for: validation), to: Validation.self)
        return method(object, validation, item).boolValue
    }
}
