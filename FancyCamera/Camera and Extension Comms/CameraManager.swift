//
//  CameraManager.swift
//  FancyCamera
//
//  Created by Denis Dzyuba on 27/3/2024.
//

import Foundation
import AVFoundation
import CoreMediaIO

enum CameraError: Error {
  case cameraUnavailable
  case cannotAddInput
  case cannotAddOutput
  case createCaptureInput(Error)
  case deniedAuthorization
  case restrictedAuthorization
  case unknownAuthorization
}

extension CameraError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .cameraUnavailable:
      return "Camera unavailable"
    case .cannotAddInput:
      return "Cannot add capture input to session"
    case .cannotAddOutput:
      return "Cannot add video output to session"
    case .createCaptureInput(let error):
      return "Creating capture input for camera: \(error.localizedDescription)"
    case .deniedAuthorization:
      return "Camera access denied"
    case .restrictedAuthorization:
      return "Attempting to access a restricted capture device"
    case .unknownAuthorization:
      return "Unknown authorization status for capture device"
    }
  }
}

class CameraManager: ObservableObject {
    enum Status {
        case unconfigured
        case configured
        case unauthorized
        case failed
        case reconfiguring
    }
    
    static let shared = CameraManager()
    
    var width: Int32 = 0
    var height: Int32 = 0
    
    /// Camera extension
    private var needToStream: Bool = false
    private var mirrorCamera: Bool = false
    private var activating: Bool = false
    private var readyToEnqueue = false
    private var enqueued = false
    private var sequenceNumber = 0

    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!
    
    var sourceStream: CMIOStreamID?
    var sinkStream: CMIOStreamID?
    var sinkQueue: CMSimpleQueue?
    ///
    
    private init() {
        configure()
    }
    
    func configure() {
        checkPermissions()
        sessionQueue.async {
            self.session.stopRunning()
            self.session = AVCaptureSession()
            self.configureCaptureSession()
            self.session.startRunning()
        }
    }
    
    @Published var error: CameraError?
    
    private var hardwareDevices: [AVCaptureDevice] = []
    private var currentDevice: AVCaptureDevice? = nil
    
    @Published var hardwareDevicesNames: [String] = []
    @Published var currentDeviceName: String = ""

    private func set(error: CameraError?) {
        DispatchQueue.main.async {
            self.error = error
        }
    }
    
    func set(
        _ delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        queue: DispatchQueue
    ) {
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(delegate, queue: queue)
        }
    }
    
    func stopCapture() {
        session.stopRunning()
    }
    
    func startCapture() {
        session.startRunning()
    }
    
    func setDeviceByNameAndPrepareReconfigure(_ name: String) {
        if currentDevice != nil {
            //Cleanup
            if let inputToKill = try? AVCaptureDeviceInput(device: currentDevice!) {
                session.removeInput(inputToKill)
            }
            session.removeOutput(videoOutput)
        }
        currentDevice = hardwareDevices.first(where: {device in device.localizedName == name})
        currentDeviceName = currentDevice?.localizedName ?? ""
        status = .reconfiguring
    }
    
    var session = AVCaptureSession()
    
    private let sessionQueue = DispatchQueue(label: "com.fansycamera.SessionQ")
    private let videoOutput = AVCaptureVideoDataOutput()
    
    private var status = Status.unconfigured

    private func checkPermissions() {
      
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .notDetermined:
        
        sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: .video) { authorized in
          
          if !authorized {
            self.status = .unauthorized
            self.set(error: .deniedAuthorization)
          }
          self.sessionQueue.resume()
        }
      
      case .restricted:
        status = .unauthorized
        set(error: .restrictedAuthorization)
      case .denied:
        status = .unauthorized
        set(error: .deniedAuthorization)
      
      case .authorized:
        break
      
      @unknown default:
        status = .unauthorized
        set(error: .unknownAuthorization)
      }
    }
    
    private func suitableDevices(in position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes:
            [.external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        
        return discoverySession.devices.filter({ device in device.localizedName != cameraName})
    }
    
    private func bestDevice(from array: [AVCaptureDevice]) -> AVCaptureDevice? {
        guard !array.isEmpty else { fatalError("Missing capture devices.")}


        return array.first(where: { device in device.localizedName != cameraName})
    }
    
    private func configureCaptureSession() {
        guard status == .unconfigured || status == .reconfiguring else {
            return
        }
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        
        let devices = status == .reconfiguring ? hardwareDevices : suitableDevices(in: .unspecified)
        
        let device = currentDevice ?? bestDevice(from: devices)
        //print(device?.localizedName)
        
        guard let camera = device else {
            set(error: .cameraUnavailable)
            status = .failed
            return
        }
        
        // An attempt, so far unsuccessful, to take
        // the hardware camera's dimensions into account
        //let dims = camera.activeFormat.formatDescription.dimensions
        DispatchQueue.main.async {
            if self.status != .reconfiguring {
                self.hardwareDevices.removeAll()
                self.hardwareDevices = devices
                
                self.hardwareDevicesNames.removeAll()
                self.hardwareDevicesNames.append(contentsOf: devices.map({$0.localizedName}))
            }
            
            self.currentDevice = device
            self.currentDeviceName = self.currentDevice?.localizedName ?? ""
            
            self.width = fixedWidth//dims.width
            self.height = fixedHeight//dims.height
            self.makeDevicesVisible()
            self.connectToCamera()
        }
        
        do {
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            
            if session.canAddInput(cameraInput) {
                session.addInput(cameraInput)
            } else {
                set(error: .cannotAddInput)
                status = .failed
                return
            }
        } catch {
            set(error: .createCaptureInput(error))
            status = .failed
            return
        }
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            
            videoOutput.videoSettings =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            
            let videoConnection = videoOutput.connection(with: .video)
            videoConnection?.videoRotationAngle = .zero//videoOrientation = .portrait
        } else {
            set(error: .cannotAddOutput)
            status = .failed
            return
        }
        status = .configured
    }
}

// MARK: - CMIO extension interaction
extension CameraManager {
    
    func makeDevicesVisible() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow : UInt32 = 1
        let dataSize : UInt32 = 4
        let zero : UInt32 = 0
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, zero, nil, dataSize, &allow)
    }

    func initSink(deviceId: CMIODeviceID, sinkStream: CMIOStreamID) {
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width, height: height, extensions: nil, formatDescriptionOut: &_videoDescription)
        
        var pixelBufferAttributes: NSDictionary!
           pixelBufferAttributes = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
        
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

        let pointerQueue = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        let pointerRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CMIOStreamCopyBufferQueue(sinkStream, {
            (sinkStream: CMIOStreamID, buf: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) in
            let sender = Unmanaged<CameraManager>.fromOpaque(refcon!).takeUnretainedValue()
            sender.readyToEnqueue = true
        },pointerRef,pointerQueue)
        if result != 0 {
            print("error starting sink")
        } else {
            if let queue = pointerQueue.pointee {
                self.sinkQueue = queue.takeUnretainedValue()
            }
            let resultStart = CMIODeviceStartStream(deviceId, sinkStream) == 0
            if resultStart {
                print("initSink started")
            } else {
                print("initSink error startstream")
            }
        }
    }

    func getDevice(name: String) -> AVCaptureDevice? {
        print("getDevice name=",name)
        var devices: [AVCaptureDevice]?
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
                                                                mediaType: .video,
                                                                position: .unspecified)
        devices = discoverySession.devices
        guard let devices = devices else { return nil }
        return devices.first { $0.localizedName == name}
    }
    
    func getCMIODevice(uid: String) -> CMIOObjectID? {
        var dataSize: UInt32 = 0
        var devices = [CMIOObjectID]()
        var dataUsed: UInt32 = 0
        var opa = CMIOObjectPropertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), .global, .main)
        CMIOObjectGetPropertyDataSize(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, &dataSize);
        let nDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        devices = [CMIOObjectID](repeating: 0, count: Int(nDevices))
        CMIOObjectGetPropertyData(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, dataSize, &dataUsed, &devices);
        for deviceObjectID in devices {
            opa.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            CMIOObjectGetPropertyDataSize(deviceObjectID, &opa, 0, nil, &dataSize)
            var name: CFString = "" as CFString
            name = withUnsafeMutablePointer(to: &name){
                CMIOObjectGetPropertyData(deviceObjectID, &opa, 0, nil, dataSize, &dataUsed, $0);
                return $0.pointee
            }

            if String(name) == uid {
                print(String(name))
                return deviceObjectID
            }
        }
        return nil
    }

    func getInputStreams(deviceId: CMIODeviceID) -> [CMIOStreamID]
    {
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var opa = CMIOObjectPropertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyStreams), .global, .main)
        CMIOObjectGetPropertyDataSize(deviceId, &opa, 0, nil, &dataSize);
        let numberStreams = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIds = [CMIOStreamID](repeating: 0, count: numberStreams)
        CMIOObjectGetPropertyData(deviceId, &opa, 0, nil, dataSize, &dataUsed, &streamIds)
        return streamIds
    }
    
    func connectToCamera() {
        if let device = getDevice(name: cameraName), let deviceObjectId = getCMIODevice(uid: device.uniqueID) {
            let streamIds = getInputStreams(deviceId: deviceObjectId)
            if streamIds.count == 2 {
                sinkStream = streamIds[1]
                print("found sink stream")
                initSink(deviceId: deviceObjectId, sinkStream: streamIds[1])
            }
            if let firstStream = streamIds.first {
                print("found source stream")
                sourceStream = firstStream
            }
        }
    }

    func registerForDeviceNotifications() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil, queue: nil) { (notif) -> Void in
            // When the user click "activate", we will receive a notification
            // we can then try to connect to our "Fancy Camera (Swift)" (if not already connected to)
            if self.sourceStream == nil {
                self.connectToCamera()
            }
        }
    }

    func unregisterFromDeviceNotifications() {
        // To be a good Mac OS citizen...
        NotificationCenter.default.removeObserver(NSNotification.Name.AVCaptureDeviceWasConnected)
    }
    
    //MARK: - This is where the frames get sent to the CMIO Extension's sink stream
    func enqueue(_ queue: CMSimpleQueue, _ image: CGImage) {
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            print("error enqueuing")
            return
        }
        var err: OSStatus = 0
        var pixelBuffer: CVPixelBuffer?
        err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
        if let pixelBuffer = pixelBuffer {
            
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
            // optimizing context: interpolationQuality and bitmapInfo
            // see https://stackoverflow.com/questions/7560979/cgcontextdrawimage-is-extremely-slow-after-large-uiimage-drawn-into-it
            if let context = CGContext(data: pixelData,
                                       width: width,
                                       height: height,
                                       bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                       space: rgbColorSpace,
                                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            {
                context.interpolationQuality = .low
                if mirrorCamera {
                    context.translateBy(x: CGFloat(width), y: 0.0)
                    context.scaleBy(x: -1.0, y: 1.0)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            
            var sbuf: CMSampleBuffer!
            var timingInfo = CMSampleTimingInfo()
            timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
            err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
            if err == 0 {
                if let sbuf = sbuf {
                    let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(sbuf).toOpaque())
                    CMSimpleQueueEnqueue(queue, element: pointerRef)
                }
            }
        } else {
            print("error getting pixel buffer")
        }
    }
}
