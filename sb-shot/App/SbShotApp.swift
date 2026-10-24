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
        MenuBarExtra {
            MenuBarView(container: container, recording: container.recordingViewModel, settings: container.settings)
        } label: {
            MenuBarLabel(recording: container.recordingViewModel)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: container.settings, fileStorage: container.fileStorage, history: container.history)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        DemoMode.startIfRequested()
        #endif
    }
}
