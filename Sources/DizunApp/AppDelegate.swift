import AppKit
import DizunCore
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WorkCoordinator()
    private var droplet: DropletWindowController?
    /// Open preview windows. Strongly held: the window does not retain its
    /// controller, so buttons and the table die with deallocation.
    private var previews: [ArchivePreviewWindowController] = []
    /// Files handed over before applicationDidFinishLaunching.
    private var pending: [URL] = []
    /// Set when the launch sequence finished; files after this are live drops.
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSApp.mainMenu = buildMainMenu()
        coordinator.requestPassword = { title, confirm in
            MainActor.assumeIsolated {
                if confirm {
                    return PasswordPrompt.requestNew()
                }
                _ = title
                return PasswordPrompt.ask(title: title)
            }
        }
        coordinator.openPreview = { [weak self] url in
            // One-shot launches (no droplet) quit when the preview's job ends;
            // with the droplet open the app stays.
            self?.showPreview(of: url, autoQuit: self?.droplet == nil)
        }
        launched = true
        if pending.isEmpty {
            droplet = DropletWindowController(coordinator: coordinator)
            droplet?.show()
        } else {
            let urls = pending
            pending = []
            runOneShot(urls, quitWhenDone: true)
        }
    }

    /// Pre-extraction preview window (contents + name-encoding switch).
    /// A reader failure (corrupt archive) is reported and, for one-shot
    /// launches, terminates. Always called on the main thread (delegate and
    /// droplet callbacks), which `assumeIsolated` asserts.
    private func showPreview(of url: URL, autoQuit: Bool) {
        MainActor.assumeIsolated {
            guard let preview = ArchivePreviewWindowController(
                archiveURL: url, coordinator: coordinator, autoQuit: autoQuit) else {
                WorkPanel.shared.showError("ZIPアーカイブとして読み込めません:\n\(url.lastPathComponent)")
                if autoQuit { NSApp.terminate(nil) }
                return
            }
            previews.append(preview)
            preview.onClose = { [weak self, weak preview] in
                guard let self, let preview else { return }
                self.previews.removeAll { $0 === preview }
            }
            preview.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard launched else {
            // Launch-with-files (Dock drop / double-click on a pinned app):
            // buffered, then run once the launch sequence completes.
            pending.append(contentsOf: urls)
            return
        }
        // Live drop while running: stay only when the user keeps a droplet
        // window open; a one-shot launch does its job and leaves (zip-porter
        // semantics — the Dock icon survives only if pinned).
        runOneShot(urls, quitWhenDone: droplet == nil)
    }

    private func runOneShot(_ urls: [URL], quitWhenDone: Bool = true) {
        coordinator.performAutomatic(urls: urls) { [weak self] in
            if quitWhenDone, self?.droplet == nil {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Menu bar

    /// Minimal application menu: About, Settings, Close, Quit. Built in code
    /// (no nib); the Services submenu keeps Finder services reachable here.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem(title: "DIZUN", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "DIZUNについて", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "閉じる", action: #selector(performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "DIZUNを終了", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }

    @objc private func showAbout() {
        MainActor.assumeIsolated {
            AboutWindowController.shared.show()
        }
    }

    @objc private func showSettings() {
        MainActor.assumeIsolated {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func performClose(_ sender: Any?) {
        NSApp.keyWindow?.performClose(nil)
    }

    // MARK: - Finder Services (NSServices in Info.plist)

    /// 暗号化なし — services are explicit and never consult the persisted
    /// droplet setting (that belongs to drag-and-drop only).
    @objc func compressService(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        coordinator.compress(files: urls, mode: .plain) { NSApp.terminate(nil) }
    }

    /// 暗号化あり — AES-256, password asked per job.
    @objc func compressEncryptedService(_ pboard: NSPasteboard, userData: String,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        coordinator.compress(files: urls, mode: .encrypted) { NSApp.terminate(nil) }
    }

    @objc func extractService(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        coordinator.extractAll(archives: urls) { NSApp.terminate(nil) }
    }

    /// 画像最適化 — in-place shrink, original to Trash per the setting.
    @objc func optimizeImagesService(_ pboard: NSPasteboard, userData: String,
                                     error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        coordinator.optimizeImages(urls) { NSApp.terminate(nil) }
    }
}

extension NSPasteboard {
    var fileURLs: [URL]? {
        let urls = (readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?
            .compactMap { $0 as URL }
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }
}
