//
//  SbShotApp.swift
//  sb-shot
//
//  Created by Jose Saul Burgos on 3/4/26.
//

import AppKit
import SwiftUI

@main
struct SbShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container = AppContainer()

    var body: some Scene {
        MenuBarExtra("sb-shot", systemImage: "camera.viewfinder") {
            MenuBarView(viewModel: container.captureViewModel)
        }

        Settings {
            SettingsView(settingsStore: container.shortcutSettingsStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
