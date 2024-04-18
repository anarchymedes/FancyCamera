//
//  ContentViewModel.swift
//  FancyCamera
//
//  Created by Denis Dzyuba on 27/3/2024.
//

import CoreImage
import CoreGraphics
import VideoToolbox
import Vision
import Dispatch

// When changing this, don't forget to make the matching changes in backgroundEffectTitles in Constants.swift
enum BackgroundEffect: Int, CaseIterable {
    case desaturate = 0
    case cmykHalftone
    case comic
    case bloom
    case gloom
    case crystallise
    case depthOfField //an vignette
    case blur
    case animate
    case none
}

// When changing this, don't forget to make the matching changes in gifResources in Constants.swift
enum BackgroundAnimation: Int, CaseIterable {
    case rainforest = 0
    case waterfall
    case island
    case storm
}

class ContentViewModel: ObservableObject {
    @Published var initialSetup: Bool = true
    @Published var frame: CGImage?
    @Published var error: Error?
    @Published var backgroundEffect: BackgroundEffect {
        willSet {
            if newValue == .animate {
                Task {
                    await updateBackgroundGIF(for: newValue)
                }
            }
        }
        didSet {
            // Load the animation for whatever GIF backgroundAnimation contains,
            // if the effect is .animate; reset the animation properties otherwise
            if oldValue == .animate {
                Task {
                    await updateBackgroundGIF(for: backgroundEffect)
                }
            }
        }
    }
    @Published var backgroundAnimation: BackgroundAnimation {
        didSet {
            // Reload the animation for the new GIF
            Task {
                await updateBackgroundGIF(for: .animate)
            }
        }
    }
    @Published var preProcessBackground: Bool = false
    @Published var fps60: Bool = false
    
    @Published var cameraManager = CameraManager.shared
    private let frameManager = FrameManager.shared
    private let context = CIContext()

    @MainActor private var gifFramesHi: [CIImage] = []
    @MainActor private var gifFramesLo: [CIImage] = []

    //GIF animation
    @MainActor private var animating = false
    @MainActor private var animDelayCount = 0
    @MainActor private var animFrameIndex = 0
    private var animFrameWidth: CGFloat = 0
    private var animFrameHeight: CGFloat = 0
    @MainActor private var gifReady = false
   
    @MainActor var currentImageTask: Task<CGImage?, Never> = Task{()->CGImage? in
        return nil
    }
    @MainActor private var lastFrame: CGImage? = nil
    
    @MainActor
    init() {
        backgroundEffect = .desaturate
        backgroundAnimation = .waterfall
        setupSubscriptions()
    }

    @MainActor
    public func resetLastFrame() {
        lastFrame = nil
    }
    
    // MARK: - Manage the GIF animations
    // If the current effect is .anitate, then load the selected GIF;
    // otherwise, clear the animation frames and reset the frame counter
    @MainActor
    private func updateBackgroundGIF(for effect: BackgroundEffect) {
        if effect == .animate {
            animating = false
            gifReady = false
            
            animDelayCount = 0
            animFrameIndex = 0
            animFrameWidth = 0
            animFrameHeight = 0
            
            //We don't want to resize the frames in real time, when they're needed,
            //so we keep the two sets: for hi-res (1980x1080) and lo-res (1280x720)
            let gifFrames = loadGifFrames(setName: gifResources[backgroundAnimation.rawValue].resourceName)
            gifFramesHi = gifFrames.hi
            gifFramesLo = gifFrames.lo
           
            gifReady = true
            animating = true
        }
        else {
            animating = false
            gifReady = false
            
            animDelayCount = 0
            animFrameIndex = 0
            animFrameWidth = 0
            animFrameHeight = 0
            
            gifFramesHi.removeAll()
            gifFramesLo.removeAll()
        }
    }
    
    private func loadGifFrames(setName gifNamed: String) -> (hi: [CIImage], lo: [CIImage])  {
        var retValHi: [CIImage] = []
        var retValLo: [CIImage] = []
        
        guard let bundleURL = Bundle.main
            .url(forResource: gifNamed, withExtension: "gif") else {
                print("This image named \"\(gifNamed)\" does not exist!")
            return (hi: [], lo: [])
        }
        
        guard let imageData = try? Data(contentsOf: bundleURL) else {
            print("Cannot turn image named \"\(gifNamed)\" into NSData")
            return (hi: [], lo: [])
        }
        
        let gifOptions = [
            kCGImageSourceShouldAllowFloat as String : true as NSNumber,
            kCGImageSourceCreateThumbnailWithTransform as String : true as NSNumber,
            kCGImageSourceCreateThumbnailFromImageAlways as String : true as NSNumber
            ] as CFDictionary
        
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, gifOptions) else {
            debugPrint("Cannot create image source with data!")
            return (hi: [], lo: [])
        }
        
        let framesCount = CGImageSourceGetCount(imageSource)
        
        for index in 0 ..< framesCount {
            
            if let cgImageRef = CGImageSourceCreateImageAtIndex(imageSource, index, nil) {
                // We assume all frames are the same size
                animFrameWidth = CGFloat(cgImageRef.width)
                animFrameHeight = CGFloat(cgImageRef.height)
                
                //Resize them just once, as they're loaded
                retValHi.append(CIImage(cgImage: cgImageRef).transformed(by: .init(scaleX: CGFloat(fixedWidth) / animFrameWidth, y: CGFloat(fixedHeight) / animFrameHeight), highQualityDownsample: true))
                retValLo.append(CIImage(cgImage: cgImageRef).transformed(by: .init(scaleX: CGFloat(fixedWidthLo) / animFrameWidth, y: CGFloat(fixedHeightLo) / animFrameHeight), highQualityDownsample: true))
            }
        }

        return (hi: retValHi, lo: retValLo)
    }
    
    // MARK: - Here, we try to move the additional graphic operations off the main thread
    // The frames from the physical camera will be received on the main thread, so it will be busy enough
    private func applyEffect(to image: CIImage, effect: BackgroundEffect) async ->CIImage {

        let work = Task.detached(priority: .high) {()->CIImage in

            if effect == .animate || effect == .none {
                return image
            }
            let frame = image.premultiplyingAlpha() // Make it thread-local
            switch effect {
            case .desaturate:
                return frame.applyingFilter("CIPhotoEffectMono")
            case .cmykHalftone:
                return frame.applyingFilter("CICMYKHalftone")
            case .comic:
                return frame.applyingFilter("CIComicEffect")
            case .bloom:
                return frame.applyingFilter("CIBloom")
            case .gloom:
                return frame.applyingFilter("CIGloom")
            case .crystallise:
                return frame.applyingFilter("CICrystallize")
            case .depthOfField:
                return frame.applyingFilter("CIDepthOfField").applyingFilter("CIVignette")
            case .blur:
                return frame.applyingFilter("CIGaussianBlur").applyingFilter("CIVignette")
            case .animate: // These last two aren't necessary: just here to stop the compiler whining
                return frame
            case .none:
                return frame
            }
        }
        return try! await work.result.get()
    }
    
    private func queueFrame(_ frame: CGImage) async {
        // This one is fire-and-forget: send the frame to the extension
        // and hope for the best
        Task.detached(priority: .medium) {
            nonisolated(unsafe) let theFrame = frame
            if let queue = CameraManager.shared.sinkQueue {
                CameraManager.shared.enqueue(queue, theFrame)
            }
        }
    }
    
    private func createMask(from frame: CGImage) async -> CGImage? {
        
        let work = Task.detached(priority: .high) {()-> CGImage? in
            nonisolated(unsafe) let image = frame  // Make them all thread-local
            nonisolated(unsafe) let context = self.context
            
            let frame = image
            
            if Task.isCancelled {
                return nil
            }
            
            //Set up the VN request to generate the foreground mask
            let segmentationRequest = VNGenerateForegroundInstanceMaskRequest()
            // perform the request
            let handler = VNImageRequestHandler(cgImage: frame, options: [.ciContext: context])
            try? handler.perform([segmentationRequest])
            
            if Task.isCancelled {
                return nil
            }
            
            guard let results = segmentationRequest.results?.first else {
                return nil
            }
            
            let masked = try? results.generateScaledMaskForImage(forInstances: results.allInstances, from: handler)
            return masked != nil ? CGImage.create(from: masked) : nil
        }
        if Task.isCancelled {
            work.cancel()
        }
        return try? await work.result.get()
    }
    
    // This function cuts out the foregroud from the background before applying
    // the selected effect: for some efects, it improves the look of the result
    private func backgroundPreProcessing(background bi: CIImage, mask: CIImage, effect: BackgroundEffect) async -> CIImage {
        let work = Task.detached(priority: .high) {()-> CIImage in
            nonisolated(unsafe) let _bi = bi
            nonisolated(unsafe) let _mask = mask.premultiplyingAlpha() // Thread-local
            nonisolated(unsafe) var maskInvert = _mask.applyingFilter("CIColorInvert")
            
            maskInvert = effect != .desaturate && effect != .depthOfField ?
            _mask.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha") :
            _mask.applyingFilter("CIColorInvert").applyingFilter("CIDiskBlur").applyingFilter("CIMaskToAlpha")
            let premult = CIFilter(name: "CIMultiplyCompositing")
            premult?.setValue(maskInvert, forKey: kCIInputImageKey)
            premult?.setValue(_bi, forKey: kCIInputBackgroundImageKey)
            return premult!.outputImage != nil ? premult!.outputImage! : _bi
        }
        return try! await work.result.get()
    }

    @MainActor
    private func getCurrentAnimFrame(background ciImage: CIImage, frames: [CIImage], index: Int)->CIImage {
        nonisolated(unsafe) let img = ciImage // Thread-local now
        nonisolated(unsafe) let gifFrames = frames // This is an array of classes - of references - so,
                                                   // the copying shouldn't slow us down too much, or eat too much memory.
                                                   // It's probably redundant - but better safe than sorry.
        let animFrameIndex = index
        
        return gifFrames.count > 0 && animFrameIndex < gifFrames.count ? gifFrames[animFrameIndex] : img
    }
    
    @MainActor
    private func nextAnimationFrame() {
        self.animDelayCount += 1
        if self.animDelayCount >= (self.fps60 ? 2 : 1) { // Every second camera frame for 60fps
            self.animDelayCount = 0
            
            self.animFrameIndex += 1
            if self.animFrameIndex >= self.gifFramesHi.count {
                self.animFrameIndex = 0
            }
        }
    }

    private func frameHandler(frame data: CVPixelBuffer?, effect: BackgroundEffect, backgroundPreProcess: Bool, animated: Bool, isGifReady: Bool) async -> CGImage? {
        
        nonisolated(unsafe) let buffer = data // Extra insurance: make them all thread-local, just in case
        let animation = animated
        let preProcessBackground = backgroundPreProcess
        let theEffect = effect
        let gifReady = isGifReady
        
        if theEffect == .none {
            if let frame = CGImage.create(from: buffer){
                return frame
            }
            else {
                return nil // Drop it
            }
        }
        
        // Checking for cancellation before every BIG step
        guard !Task.isCancelled else {return nil}
        
        if let image = CGImage.create(from: buffer) {
            
            var ciImage = CIImage(cgImage: image)
            
            let originalSize = ciImage.extent.size
            let hi = originalSize.width == CGFloat(fixedWidth)
            
            // Checking for cancellation before every BIG step
            guard !Task.isCancelled else {return nil}
            
            // Get the mask
            if let cgMask = await createMask(from: image) {
                //...and use it
                var maskImage = CIImage(cgImage: cgMask)
                
                // Checking for cancellation before every BIG step
                guard !Task.isCancelled else {return nil}

                maskImage = maskImage.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2.4])
                
                var background = ciImage
                
                // Checking for cancellation before every BIG step
                guard !Task.isCancelled else {return nil}

                if await animating {
                    // This gives us the next frame of the chosen animation for a background
                    let currentAnimFrame = await getCurrentAnimFrame(background: ciImage, frames: hi ? gifFramesHi : gifFramesLo, index: animFrameIndex)
                    background = gifReady ? currentAnimFrame : ciImage
                }

                // Checking for cancellation before every BIG step
                guard !Task.isCancelled else {return nil}

                if preProcessBackground {
                    background = await backgroundPreProcessing(background: background, mask: maskImage, effect: backgroundEffect)
                }
                
                maskImage = maskImage.applyingFilter("CIMaskToAlpha")
          
                // Checking for cancellation before every BIG step
                guard !Task.isCancelled else {return nil}
                
                if animation {
                    // Loop through the selected animation's frames: move the counter to the next or the first one
                    await nextAnimationFrame()
                } else {
                    // Apply the chosen effect to the background
                    background = await self.applyEffect(to: background, effect: backgroundEffect)
                }
                
                // Checking for cancellation before every BIG step
                guard !Task.isCancelled else {return nil}

                // Blend the foreground and the background by the mask:
                // this had better remain on the current thread, to avoid extra hickups
                // The problem is, if we're not using the animation, our background ALSO
                // contains the foreground (the person), albeit with an effect applied, so
                // any gaps in the mask may not stand out so prominently as they do with
                // the animations that do NOT contain the person.
                let filterLast = CIFilter(name: "CIBlendWithMask")
                filterLast?.setValue(background, forKey: kCIInputBackgroundImageKey)
                filterLast?.setValue(ciImage, forKey: kCIInputImageKey)
                filterLast?.setValue(maskImage, forKey: kCIInputMaskImageKey)
                
                if filterLast!.outputImage != nil {
                    ciImage = filterLast!.outputImage!
                }
                else { // Just drop it
                    return nil
                }
            }
            else {
                return nil // This will drop the defective frame for which no mask could be created
            }
            
            let final = self.context.createCGImage(ciImage, from: ciImage.extent)
            return final
        }
        else {
            return nil // Drop it if we couldn't convert the CVPixelBuffer to an image
        }
    }
    
    // MARK: - The big kahuna
    @MainActor
    func setupSubscriptions() {
        cameraManager.$error
          .receive(on: RunLoop.main)
          .map { $0 }
          .assign(to: &$error)
        
        frameManager.$current
            .receive(on: RunLoop.main)
            .asyncMap { buffer in // This will run on the main thread, but will allow anychronous code
                self.currentImageTask.cancel() // This will drop the previous frame if it hasn't finished rendering
                
                nonisolated(unsafe) let data = buffer
                self.currentImageTask = Task {
                    return await self.frameHandler(frame: data, effect: self.backgroundEffect, backgroundPreProcess: self.preProcessBackground, animated: self.animating, isGifReady: self.gifReady)
                }
                
                do {
                    let frame = try await self.currentImageTask.result.get()
                    if frame != nil {
                        self.lastFrame = frame // Cache the last successfully rendered frame
                    }
                } catch {
                    // Nothing
                }
                
                // Forward to the extension and return ONLY the successfully rendered frames, in the correct order:
                // otherwise, the picture sometimes jumps back and forth, the previous frame appearing after the
                // next one, especially on a hi-res camera, such as an iPhone, where the segmentation takes a long time;
                // better to just drop the frames that come too late.
                if self.lastFrame != nil { // Only the very first one should be nil
                    await self.queueFrame(self.lastFrame!)
                }
                return self.lastFrame
            }
            .assign(to: &$frame)
    }
}

extension CGImage {
  static func create(from cvPixelBuffer: CVPixelBuffer?) -> CGImage? {
    guard let pixelBuffer = cvPixelBuffer else {
      return nil
    }

    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(
      pixelBuffer,
      options: nil,
      imageOut: &image)
    return image
  }
}
