import AppKit

let app = NSApplication.shared
let documentController = BristleDocumentController()
AppPreferences.registerDefaults()
AppPreferences.applyAppearance()
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
#if BRISTLE_CHECKS
  AppChecks.run(controller: documentController)
#endif
withExtendedLifetime((delegate, documentController)) { app.run() }
