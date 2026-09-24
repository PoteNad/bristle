import AppKit
import BristleCanvas
import BristleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private lazy var settingsController = SettingsWindowController()
  private let recentMenu = NSMenu(title: "Open Recent")

  // Menus are built before windows are restored or opened, so the menu bar is never empty
  // while the first document appears.
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true
    buildMenus()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if BRISTLE_CHECKS
      // Automated checks run in the background so they never take keyboard focus from the user.
      if AppChecks.isChecking { return }
    #endif
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func buildMenus() {
    let bar = NSMenu()
    NSApp.mainMenu = bar

    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      item.submenu = menu
      bar.addItem(item)
      return menu
    }

    func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      item.submenu = menu
      parent.addItem(item)
      return menu
    }

    @discardableResult
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
      modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      if let tag { item.tag = tag }
      menu.addItem(item)
      return item
    }

    let app = menu("Bristle")
    add(app, "About Bristle", #selector(showAbout(_:)), target: self)
    app.addItem(.separator())
    add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
    app.addItem(.separator())
    let services = submenu(app, "Services")
    NSApp.servicesMenu = services
    app.addItem(.separator())
    add(app, "Hide Bristle", #selector(NSApplication.hide(_:)), "h")
    add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
    add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    add(app, "Quit Bristle", #selector(NSApplication.terminate(_:)), "q")

    let file = menu("File")
    add(file, "New Window", #selector(NSDocumentController.newDocument(_:)), "n")
    add(file, "New Tab", #selector(BristleDocumentController.newWindowForTab(_:)), "t")
    add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
    let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    recentItem.submenu = recentMenu
    recentMenu.delegate = self
    file.addItem(recentItem)
    file.addItem(.separator())
    add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
    add(file, "Save", #selector(NSDocument.save(_:)), "s")
    add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
    add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
    file.addItem(.separator())
    add(file, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", modifiers: [.command, .shift, .option])
    add(file, "Rename…", #selector(NSDocument.rename(_:)))
    add(file, "Move To…", #selector(NSDocument.move(_:)))
    file.addItem(.separator())
    add(file, "Insert Image…", #selector(Editor.insertImage(_:)), "i", modifiers: [.command, .shift])
    // AppKit fills this in with Continuity Camera and Sketch for nearby iPhones and iPads.
    let device = add(file, "Import from iPhone or iPad", nil)
    device.identifier = NSMenuItem.importFromDeviceIdentifier
    file.addItem(.separator())
    add(file, "Export…", #selector(BristleDocument.exportDrawing(_:)), "e", modifiers: [.command, .shift])
    file.addItem(.separator())
    add(file, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", modifiers: [.command, .shift])
    add(file, "Print…", #selector(NSDocument.printDocument(_:)), "p")

    let edit = menu("Edit")
    add(edit, "Undo", #selector(CanvasView.undo(_:)), "z")
    add(edit, "Redo", #selector(CanvasView.redo(_:)), "z", modifiers: [.command, .shift])
    edit.addItem(.separator())
    add(edit, "Cut", #selector(NSText.cut(_:)), "x")
    add(edit, "Copy", #selector(NSText.copy(_:)), "c")
    add(edit, "Paste", #selector(NSText.paste(_:)), "v")
    add(edit, "Duplicate", #selector(CanvasView.duplicate(_:)), "d")
    add(edit, "Delete", #selector(NSText.delete(_:)))
    edit.addItem(.separator())
    add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
    add(edit, "Deselect All", #selector(CanvasView.deselectAll(_:)), "a", modifiers: [.command, .shift])
    add(edit, "Invert Selection", #selector(CanvasView.invertSelection(_:)))

    let format = menu("Format")
    add(format, "Show Palette", #selector(Editor.togglePalette(_:)), "c", modifiers: [.command, .shift])
    add(format, "Show Fonts", #selector(Editor.showFonts(_:)), "t", modifiers: [.command, .option])
    let bold = add(format, "Bold", #selector(NSFontManager.addFontTrait(_:)), "b", target: NSFontManager.shared)
    bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
    let italic = add(format, "Italic", #selector(NSFontManager.addFontTrait(_:)), "i", target: NSFontManager.shared)
    italic.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
    format.addItem(.separator())
    add(format, "Remove Background", #selector(CanvasView.removeBackground(_:)))
    format.addItem(.separator())
    add(format, "Copy Style", #selector(CanvasView.copyStyle(_:)), "c", modifiers: [.command, .option])
    add(format, "Paste Style", #selector(CanvasView.pasteStyle(_:)), "v", modifiers: [.command, .option])

    let arrange = menu("Arrange")
    add(arrange, "Bring to Front", #selector(CanvasView.bringToFront(_:)), "f", modifiers: [.command, .shift])
    add(arrange, "Bring Forward", #selector(CanvasView.bringForward(_:)), "f", modifiers: [.command, .option, .shift])
    add(arrange, "Send Backward", #selector(CanvasView.sendBackward(_:)), "b", modifiers: [.command, .option, .shift])
    add(arrange, "Send to Back", #selector(CanvasView.sendToBack(_:)), "b", modifiers: [.command, .shift])
    arrange.addItem(.separator())
    let align = submenu(arrange, "Align Objects")
    for (i, title) in ["Left", "Center", "Right", "Top", "Middle", "Bottom"].enumerated() {
      add(align, title, #selector(CanvasView.alignObjects(_:)), tag: i)
      if i == 2 { align.addItem(.separator()) }
    }
    let distribute = submenu(arrange, "Distribute Objects")
    add(distribute, "Horizontally", #selector(CanvasView.distributeHorizontally(_:)))
    add(distribute, "Vertically", #selector(CanvasView.distributeVertically(_:)))
    arrange.addItem(.separator())
    add(arrange, "Rotate Left", #selector(CanvasView.rotateLeft(_:)))
    add(arrange, "Rotate Right", #selector(CanvasView.rotateRight(_:)))
    add(arrange, "Flip Horizontally", #selector(CanvasView.flipHorizontal(_:)))
    add(arrange, "Flip Vertically", #selector(CanvasView.flipVertical(_:)))
    arrange.addItem(.separator())
    add(arrange, "Lock", #selector(CanvasView.lock(_:)), "l")
    add(arrange, "Unlock All", #selector(CanvasView.unlockAll(_:)), "l", modifiers: [.command, .option])
    arrange.addItem(.separator())
    add(arrange, "Group", #selector(CanvasView.group(_:)), "g", modifiers: [.command, .option])
    add(arrange, "Ungroup", #selector(CanvasView.ungroup(_:)), "g", modifiers: [.command, .option, .shift])

    let canvas = menu("Canvas")
    add(canvas, "Add Frame", #selector(CanvasView.toggleFrame(_:)))
    add(canvas, "Frame Size…", #selector(Editor.showFrameSize(_:)))
    add(canvas, "Frame Selection", #selector(CanvasView.cropToSelection(_:)), "k")
    add(canvas, "Fit Frame to Drawing", #selector(CanvasView.fitCanvasToDrawing(_:)))
    canvas.addItem(.separator())
    let background = submenu(canvas, "Background")
    add(background, "None", #selector(Editor.chooseBackground(_:)), tag: 0)
    add(background, "White", #selector(Editor.chooseBackground(_:)), tag: 1)
    add(background, "Color…", #selector(Editor.chooseBackground(_:)), tag: 2)
    canvas.addItem(.separator())
    add(canvas, "Rotate Drawing Left", #selector(CanvasView.rotateCanvasLeft(_:)))
    add(canvas, "Rotate Drawing Right", #selector(CanvasView.rotateCanvasRight(_:)))
    add(canvas, "Flip Drawing Horizontally", #selector(CanvasView.flipCanvasHorizontal(_:)))
    add(canvas, "Flip Drawing Vertically", #selector(CanvasView.flipCanvasVertical(_:)))

    let view = menu("View")
    let tools = submenu(view, "Tool")
    for tool in Tool.allCases {
      let item = add(tools, tool.title, #selector(Editor.chooseTool(_:)))
      item.representedObject = tool.rawValue
      item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
      item.toolTip = tool.key.isEmpty ? nil : "Press \(tool.key.uppercased()) on the canvas"
      if [.select, .pixel, .strokeEraser, .arrow, .polygon, .text, .fill].contains(tool) { tools.addItem(.separator()) }
    }
    view.addItem(.separator())
    add(view, "Zoom In", #selector(CanvasView.zoomIn(_:)), "+")
    add(view, "Zoom Out", #selector(CanvasView.zoomOut(_:)), "-")
    add(view, "Actual Size", #selector(CanvasView.actualSize(_:)), "0")
    add(view, "Zoom to Fit", #selector(CanvasView.zoomToFit(_:)), "9")
    add(view, "Zoom to Selection", #selector(CanvasView.zoomToSelection(_:)), "9", modifiers: [.command, .option])
    view.addItem(.separator())
    add(view, "Show Grid", #selector(Editor.toggleGrid(_:)), "'")
    add(view, "Show Rulers", #selector(Editor.toggleRulers(_:)), "r")
    add(view, "Snap to Grid", #selector(Editor.toggleSnapToGrid(_:)), "'", modifiers: [.command, .shift])
    add(view, "Snap to Guides", #selector(Editor.toggleGuides(_:)))
    view.addItem(.separator())
    add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])

    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    window.addItem(.separator())
    add(window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift])
    add(window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift])
    add(window, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
    add(window, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
    window.addItem(.separator())
    add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = window

    let help = menu("Help")
    add(help, "Bristle on GitHub", #selector(openGitHub(_:)), target: self)
    NSApp.helpMenu = help
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === recentMenu else { return }
    menu.removeAllItems()
    let urls = NSDocumentController.shared.recentDocumentURLs
    if urls.isEmpty {
      let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return
    }
    for url in urls {
      let item = NSMenuItem(
        title: FileManager.default.displayName(atPath: url.path), action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = url
      item.toolTip = url.path
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
  }

  @objc func showAbout(_ sender: Any?) {
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    // Like PoteNad and Plainst, show only the version, not the build number.
    NSApp.orderFrontStandardAboutPanel(options: [
      .version: "",
      .credits: NSAttributedString(
        string: "A small, native drawing app where everything stays editable.",
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
          .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered,
        ]),
    ])
  }

  @objc private func showSettings(_ sender: Any?) { settingsController.show() }

  @objc private func openRecent(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
      if let error { NSApp.presentError(error) }
    }
  }

  @objc private func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

  @objc private func openGitHub(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://github.com/PoteNad/bristle")!)
  }
}
