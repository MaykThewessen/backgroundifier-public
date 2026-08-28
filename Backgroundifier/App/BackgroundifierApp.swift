//
//  BackgroundifierApp.swift
//  Backgroundifier
//
//  SwiftUI application entry point (GUI mode). The bgify target provides the CLI.
//  2026 upgrade by Mayk Thewessen.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // handles dropping files onto the app icon / "Open With"
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.add(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BackgroundifierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Backgroundifier", id: "main") {
            ContentView()
                .environment(AppModel.shared)
        }
        .defaultSize(width: 540, height: 720)
    }
}
