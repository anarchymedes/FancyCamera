//
//  ContentView.swift
//  FancyCamera
//
//  Created by Denis Dzyuba on 27/3/2024.
//

import SwiftUI
import SystemExtensions

struct ContentView: View {
    // The extension request delegate, defined below (can't be just self)
    private let theDelegate = ContentViewExtDelegate()
    
    @EnvironmentObject private var model: ContentViewModel
    
    @State private var alertShowing: Bool = false
    @State private var alertMessage: String = ""

    func presentAlert(with text: String) {
        alertMessage = text
        alertShowing = true
    }

    private func _extensionBundle() -> Bundle {
        let extensionsDirectoryURL = URL(fileURLWithPath: extensionPath, relativeTo: Bundle.main.bundleURL)
        let extensionURLs: [URL]
        do {
            extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL,
                                                                        includingPropertiesForKeys: nil,
                                                                        options: .skipsHiddenFiles)
        } catch let error {
            fatalError("Failed to get the contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)")
        }
        
        guard let extensionURL = extensionURLs.first else {
            fatalError("Failed to find any system extensions")
        }
        guard let extensionBundle = Bundle(url: extensionURL) else {
            fatalError("Failed to find any system extensions")
        }
        return extensionBundle
    }
    
    // Activate the extension
    private func activate() {
        guard let extensionIdentifier = _extensionBundle().bundleIdentifier else {
            return
        }
        theDelegate.activating = true
        let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        theDelegate.alertPresenter = presentAlert
        activationRequest.delegate = theDelegate
        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }
    
    //Deactivate the extension
    private func deactivate() {
        guard let extensionIdentifier = _extensionBundle().bundleIdentifier else {
            return
        }

        theDelegate.activating = false
        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        theDelegate.alertPresenter = presentAlert
        deactivationRequest.delegate = theDelegate
        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }
    
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - The body
    var body: some View {
        ZStack {
            FrameView(image: model.frame)
              .edgesIgnoringSafeArea(.all)
            VStack{
                Spacer()
                VStack(spacing: 0) {
                    // Activate/Deactivate/Quit buttons
                    HStack {
                        Spacer()
                        
                        Button(action: {activate()}, label: {
                            Text("Activate")
                        })
                        .padding(.horizontal, 1.5)
                        .help("Install the Fancy Camera virtual camera")
                        
                        Button(action: {deactivate()}, label: {
                            Text("Deactivate")
                        })
                        .padding(.horizontal, 1.5)
                        .help("Uninstall the Fancy Camera virtual camera")

                        Spacer()
                        
                        Button(action: {quit()}, label: {
                            Image(systemName: "power")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundStyle(LinearGradient(colors: [.pink, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                        })
                        .clipShape(Circle())
                        .help("Quit the app")
                    }
                    .padding(.vertical, 5)
                    
                    // Device selection
                    HStack {
                        Picker("Hardware camera", selection: $model.cameraManager.currentDeviceName) {
                            ForEach(model.cameraManager.hardwareDevicesNames, id: \.self) {
                                Text($0)
                            }
                        }
                        .onChange(of: model.cameraManager.currentDeviceName){oldVal, newVal in
                            if (newVal != oldVal) {
                                if !model.initialSetup {
                                    model.cameraManager.stopCapture()
                                    
                                    model.cameraManager.setDeviceByNameAndPrepareReconfigure(model.cameraManager.currentDeviceName)
                                    model.cameraManager.configure()
                                }
                                else {
                                    model.initialSetup = false
                                }
                            }
                        }
                        .padding(.horizontal, 1.5)
                        .disabled(model.hq)

                        Spacer()
                    }
                    .padding(.vertical, 2.5)
                   
                    // Configuration controls
                    HStack {
                        Picker("Background effect", selection: $model.backgroundEffect) {
                            ForEach(BackgroundEffect.allCases, id: \.self){
                                Text(backgroundEffectTitles[$0.rawValue])
                            }
                        }
                        .padding(.horizontal, 1.5)
                        .disabled(model.hq)

                        Toggle("Pre-process Background", isOn: $model.preProcessBackground)
                            .padding(.horizontal, 1.5)
                            .disabled(model.backgroundEffect == .none)

                        Picker("Background animation", selection: $model.backgroundAnimation){
                            ForEach(BackgroundAnimation.allCases, id: \.self) {
                                Text(gifResources[$0.rawValue].UITtitle)
                            }
                        }
                        .padding(.horizontal, 1.5)
                        .disabled(model.backgroundEffect != .animate || model.hq)

                        Toggle("HQ", isOn: $model.hq)
                            .padding(.horizontal, 1.5)
                            .disabled(model.backgroundEffect == .none)

                        Toggle("60 FPS", isOn: $model.fps60)
                            .padding(.horizontal, 1.5)
                            .disabled(model.backgroundEffect == .none)
                    }
                    .padding()
                }
                .background(.ultraThinMaterial)
            }
        }
        .padding()
        .onAppear(){
            CameraManager.shared.registerForDeviceNotifications()
        }
        .onDisappear() {
            CameraManager.shared.unregisterFromDeviceNotifications()
        }
        .alert(alertMessage, isPresented: $alertShowing) {
            Button("OK", role: .cancel) { alertMessage = ""}
        }
    }
}

// MARK: - The delegate
class ContentViewExtDelegate: NSObject, OSSystemExtensionRequestDelegate
{
    var activating: Bool = false
    
    var alertPresenter: ((String)->Void)? = nil
    
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        alertPresenter?("Replacing extension version \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        alertPresenter?("Extension needs user approval")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("Request finished with result: \(result.rawValue)")
        if result == .completed {
            if self.activating {
                alertPresenter?("The camera is activated")
            } else {
                alertPresenter?("The camera is deactivated")
            }
        } else {
            if self.activating {
                alertPresenter?("Please reboot to finish activating the Fancy camera")
            } else {
                alertPresenter?("Please Reboot to finish deactivating the Fancy camera")
            }
        }
    }

    private func errorDescription(_ error: Error)->String {
        var description = ""
        if error is OSSystemExtensionError {
            switch(error as! OSSystemExtensionError).code {
            case OSSystemExtensionError.Code.unknown:
                description = "Unknown error"
            case OSSystemExtensionError.Code.missingEntitlement:
                description = "Missing entitlement"
            case OSSystemExtensionError.Code.unsupportedParentBundleLocation:
                description = "Unsupported parent bundle location"
            case OSSystemExtensionError.Code.extensionNotFound:
                description = "Extension not found"
            case OSSystemExtensionError.Code.extensionMissingIdentifier:
                description = "Extension missing identifier"
            case OSSystemExtensionError.Code.duplicateExtensionIdentifer:
                description = "Duplicate extension identifier"
            case OSSystemExtensionError.Code.unknownExtensionCategory:
                description = "Unknown extension category"
            case OSSystemExtensionError.Code.codeSignatureInvalid:
                description = "Code signature invalid"
            case OSSystemExtensionError.Code.validationFailed:
                description = "Validation failed"
            case OSSystemExtensionError.Code.forbiddenBySystemPolicy:
                description = "Forbidden by system policy"
            case OSSystemExtensionError.Code.requestCanceled:
                description = "Request cancelled"
            case OSSystemExtensionError.Code.requestSuperseded:
                description = "Request superseded"
            case OSSystemExtensionError.Code.authorizationRequired:
                description = "Authorisation required"
            default:
                description = error.localizedDescription
            }
        } else {
            description = error.localizedDescription
        }
        return description
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if self.activating {
            alertPresenter?("Failed to activate the camera: \(errorDescription(error))")
        } else {
            alertPresenter?("Failed to deactivate the camera: \(errorDescription(error))")
        }
    }
}

// MARK: - The preview
#Preview {
    ContentView()
}
