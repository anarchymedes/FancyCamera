//
//  main.swift
//  CameraExtension
//
//  Created by Denis Dzyuba on 31/3/2024.
//

import Foundation
import CoreMediaIO

let providerSource = CameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
