//
//  FancyCameraApp.swift
//  FancyCamera
//
//  Created by Denis Dzyuba on 27/3/2024.
//

import SwiftUI

@main
struct FancyCameraApp: App {
    @StateObject private var model = ContentViewModel()
    
    var mainWindow = ContentView()
    
    var body: some Scene {
        WindowGroup("Fancy Camera", id: "fancycamera") {
            mainWindow
                .environmentObject(model)
        }
        
        MenuBarExtra("Fancy Camera", systemImage: "camera.macro.circle.fill") {
            mainWindow
                .frame(width: 1024, height: 768)
                .fixedSize()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
