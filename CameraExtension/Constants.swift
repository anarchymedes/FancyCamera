//
//  Constants.swift
//  CameraExtension
//
//  Created by Denis Dzyuba on 1/4/2024.
//

import Foundation

let cameraName = "Fancy Camera"
let fixedWidth: Int32 = 1920
let fixedHeight: Int32 = 1080
let fixedWidthLo: Int32 = 1280
let fixedHeightLo: Int32 = 720


let extensionPath = "Contents/Library/SystemExtensions"

// The number and order of elements here MUST match the number and order of cases
// in the BackgroundAnimation enum in ContentViewModel.swift
let gifResources: [GIFResource] = [
    GIFResource(resourceName: "forest-rain", UITtitle: "Rainforest"),
    GIFResource(resourceName: "falls-nature", UITtitle: "Fantasy Waterfall"),
    GIFResource(resourceName: "dominicano", UITtitle: "Island Retreat"),
    GIFResource(resourceName: "tornado-horizontal", UITtitle: "Stormy Skies")
]

// The number and order of elements here MUST match the number and order of cases
// in the BackgroundEffect enum in ContentViewModel.swift
let backgroundEffectTitles: [String] = [
    "Desaturate",
    "CMYK Halftone",
    "Comic",
    "Bloom",
    "Gloom",
    "Crystallise",
    "Depth of Field",
    "Blur",
    "Animation",
    "None"
]
