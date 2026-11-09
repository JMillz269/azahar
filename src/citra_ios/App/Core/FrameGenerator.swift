// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import AzaharCore
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Makes the frame between two finished frames with Apple's low-latency frame interpolation
/// (VideoToolbox, iOS 26). The renderer draws each frame into one of the slots; a slot is a Metal
/// texture on top of a pixel buffer, because the interpolation works on pixel buffers.
///
/// Everything here runs on the renderer's thread.
final class FrameGenerator: NSObject, AZFrameGenerating {
    static let shared = FrameGenerator()

    /// Whether this iOS version and device can interpolate frames.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
    }

    /// A frame as the interpolation takes it: 4:2:0 YCbCr in two planes.
    private struct Slot {
        let buffer: CVPixelBuffer
        let luma: MTLTexture
        let chroma: MTLTexture
    }

    private static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    private static let slotCount = 4

    private var slots: [Slot] = []
    /// The VTFrameProcessor, kept as AnyObject so this file also builds for older iOS versions.
    private var processor: AnyObject?
    private var frameCounter: Int64 = 0
    nonisolated(unsafe) private static var failures = 0

    func prepare(device: MTLDevice, width: Int, height: Int) -> Bool {
        slots = []
        processor = nil
        guard #available(iOS 26.0, *) else { return false }
        return prepareSession(device: device, width: width, height: height)
    }

    @available(iOS 26.0, *)
    private func prepareSession(device: MTLDevice, width: Int, height: Int) -> Bool {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1)
        else {
            Self.log("frame interpolation does not take \(width)x\(height) frames")
            return false
        }
        let formats = configuration.supportedPixelFormats
        Self.log("frame interpolation pixel formats: "
                 + formats.map { String(format: "0x%08X", $0) }.joined(separator: ", "))
        // The renderer converts its frames into this format.
        guard formats.contains(Self.pixelFormat) else {
            Self.log("frame interpolation does not take 4:2:0 YCbCr frames")
            return false
        }

        // The buffers have to be what the processor asks for (its attributes), for the frames it
        // reads and for the one it writes, since every slot takes both roles.
        var attributes: [String: Any] = [:]
        for (key, value) in configuration.sourcePixelBufferAttributes { attributes[key] = value }
        for (key, value) in configuration.destinationPixelBufferAttributes {
            attributes[key] = value
        }
        Self.log("frame interpolation buffer attributes: "
                 + attributes.keys.sorted().joined(separator: ", "))

        var created: [Slot] = []
        for _ in 0..<Self.slotCount {
            guard let slot = makeSlot(device: device, width: width, height: height,
                                      required: attributes) else {
                Self.log("frame interpolation could not make its \(width)x\(height) buffers")
                return false
            }
            created.append(slot)
        }

        let processor = VTFrameProcessor()
        do {
            // Loads the model, which can take a moment.
            try processor.startSession(configuration: configuration)
        } catch {
            Self.log("starting frame interpolation failed: \(error)")
            return false
        }
        Self.log("frame interpolation started for \(width)x\(height) frames")
        self.slots = created
        self.processor = processor
        self.frameCounter = 0
        return true
    }

    private func makeSlot(device: MTLDevice, width: Int, height: Int,
                          required: [String: Any]) -> Slot? {
        var attributes = required
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = Self.pixelFormat
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        if attributes[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, Self.pixelFormat,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return nil }

        // The renderer writes BT.709 video range; video processors read the color description
        // from these attachments.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        func plane(_ index: Int, format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: CVPixelBufferGetWidthOfPlane(buffer, index),
                height: CVPixelBufferGetHeightOfPlane(buffer, index), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface,
                                      plane: index)
        }
        guard let luma = plane(0, format: .r8Unorm), let chroma = plane(1, format: .rg8Unorm)
        else { return nil }
        return Slot(buffer: buffer, luma: luma, chroma: chroma)
    }

    /// Into the emulator log, which is the one users send.
    private static func log(_ message: String) {
        AZEmulator.log("Frame generation: " + message)
    }

    func texture(slot: Int, plane: Int) -> MTLTexture? {
        guard slots.indices.contains(slot) else { return nil }
        return plane == 0 ? slots[slot].luma : slots[slot].chroma
    }

    func interpolate(from previous: Int, to current: Int, into destination: Int,
                     completion: @escaping (Bool) -> Void) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return start(from: previous, to: current, into: destination, completion: completion)
    }

    @available(iOS 26.0, *)
    private func start(from previous: Int, to current: Int, into destination: Int,
                       completion: @escaping (Bool) -> Void) -> Bool {
        guard let processor = processor as? VTFrameProcessor,
              slots.indices.contains(previous), slots.indices.contains(current),
              slots.indices.contains(destination)
        else { return false }

        // The frames get increasing times, the made frame sits halfway between its neighbours.
        frameCounter += 1
        let n = frameCounter
        guard let previousFrame = VTFrameProcessorFrame(
                buffer: slots[previous].buffer,
                presentationTimeStamp: CMTime(value: 2 * (n - 1), timescale: 60)),
              let sourceFrame = VTFrameProcessorFrame(
                buffer: slots[current].buffer,
                presentationTimeStamp: CMTime(value: 2 * n, timescale: 60)),
              let destinationFrame = VTFrameProcessorFrame(
                buffer: slots[destination].buffer,
                presentationTimeStamp: CMTime(value: 2 * n - 1, timescale: 60)),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFrame, previousFrame: previousFrame,
                interpolationPhase: [0.5], destinationFrames: [destinationFrame])
        else { return false }

        // The interpolation does not run on the renderer's GPU queue: wait for it to be done
        // before the made frame is shown.
        processor.process(parameters: parameters) { _, error in
            if let error {
                // Log the first ones, then now and then: it fails for every frame when it fails.
                Self.failures += 1
                if Self.failures <= 3 || Self.failures % 600 == 0 {
                    Self.log("making a frame failed (\(Self.failures) so far): \(error)")
                }
            }
            completion(error == nil)
        }
        return true
    }
}
