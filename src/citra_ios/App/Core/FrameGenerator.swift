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

    private struct Slot {
        let buffer: CVPixelBuffer
        let texture: MTLTexture
    }

    private static let slotCount = 4

    private var slots: [Slot] = []
    /// The VTFrameProcessor, kept as AnyObject so this file also builds for older iOS versions.
    private var processor: AnyObject?
    private var frameCounter: Int64 = 0

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
        // The renderer draws BGRA, so the interpolation has to take that.
        guard formats.contains(kCVPixelFormatType_32BGRA) else {
            Self.log("frame interpolation does not take BGRA frames")
            return false
        }

        var created: [Slot] = []
        for _ in 0..<Self.slotCount {
            guard let slot = makeSlot(device: device, width: width, height: height) else {
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

    private func makeSlot(device: MTLDevice, width: Int, height: Int) -> Slot? {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface,
                                               plane: 0)
        else { return nil }
        return Slot(buffer: buffer, texture: texture)
    }

    /// Into the emulator log, which is the one users send.
    private static func log(_ message: String) {
        AZEmulator.log("Frame generation: " + message)
    }

    func texture(slot: Int) -> MTLTexture? {
        slots.indices.contains(slot) ? slots[slot].texture : nil
    }

    func interpolate(from previous: Int, to current: Int, into destination: Int,
                     commandBuffer: MTLCommandBuffer) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return encode(from: previous, to: current, into: destination, commandBuffer: commandBuffer)
    }

    @available(iOS 26.0, *)
    private func encode(from previous: Int, to current: Int, into destination: Int,
                        commandBuffer: MTLCommandBuffer) -> Bool {
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

        processor.process(with: commandBuffer, parameters: parameters)
        return true
    }
}
