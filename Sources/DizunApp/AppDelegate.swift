import AppKit
import DizunCore
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = WorkCoordinator()
    private var droplet: DropletWindowController?
    /// Files handed over before applicationDidFinishLaunching.
    private var pending: [URL] = []
    /// True when launched to do one job (open/service) — quit when it ends.
    private var oneShot = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        if pending.isEmpty {
            droplet = DropletWindowController(coordinator: coordinator)
            droplet?.show()
        } else {
            let urls = pending
            pending = []
            runOneShot(urls)
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
        if NSApp.isActive || droplet != nil {
            // Already running (droplet mode): queue without quitting.
            runOneShot(urls, quitWhenDone: false)
        } else {
            pending.append(contentsOf: urls)
            oneShot = true
        }
    }

    private func runOneShot(_ urls: [URL], quitWhenDone: Bool = true) {
        coordinator.performAutomatic(urls: urls) { [weak self] in
            if quitWhenDone, self?.droplet == nil {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Finder Services (NSServices in Info.plist)

    @objc func compressService(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        oneShot = true
        coordinator.compress(files: urls) { NSApp.terminate(nil) }
    }

    @objc func extractService(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pboard.fileURLs else {
            error?.pointee = "no files on the pasteboard" as NSString
            return
        }
        oneShot = true
        coordinator.extractAll(archives: urls) { NSApp.terminate(nil) }
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
