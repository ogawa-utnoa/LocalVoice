import Foundation
import ApplicationServices
import AppKit

public struct FocusedElementInfo {
    public let element: AXUIElement?
    public let isSecure: Bool
    public let role: String?
    public let subrole: String?
    public let appName: String?
}

public struct InputTargetDetector {

    /// Detects the currently focused element in the frontmost app.
    public static func getFocusedElement() -> FocusedElementInfo {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let systemWide = AXUIElementCreateSystemWide()
        // A hung target app must not freeze us for the default 6 seconds
        AXUIElementSetMessagingTimeout(systemWide, 1.0)

        var focusedAppValue: AnyObject?
        let appErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue)
        guard appErr == .success, let focusedApp = focusedAppValue,
              CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else {
            return FocusedElementInfo(element: nil, isSecure: false, role: nil, subrole: nil, appName: appName)
        }

        let appElement = focusedApp as! AXUIElement
        var focusedUIElementValue: AnyObject?
        let elemErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedUIElementValue)

        guard elemErr == .success, let focusedUIElement = focusedUIElementValue,
              CFGetTypeID(focusedUIElement) == AXUIElementGetTypeID() else {
            return FocusedElementInfo(element: nil, isSecure: false, role: nil, subrole: nil, appName: appName)
        }

        let targetElement = focusedUIElement as! AXUIElement

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(targetElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(targetElement, kAXSubroleAttribute as CFString, &subroleValue)
        let subrole = subroleValue as? String

        // Check for secure fields (passwords)
        let isSecure = (subrole == "AXSecureTextField") || (role == "AXSecureTextField")

        return FocusedElementInfo(element: targetElement, isSecure: isSecure, role: role, subrole: subrole, appName: appName)
    }
}
