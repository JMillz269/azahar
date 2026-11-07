// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "citra_ios/Bridge/camera_ios.h"
#include "common/logging/log.h"
#include "core/frontend/camera/factory.h"
#include "core/frontend/camera/interface.h"
#include "core/hle/service/cam/cam.h"

namespace {

/// The newest frame of a capture session. Written by the capture queue, read by the emulation
/// thread.
struct FrameStore {
    std::mutex mutex;
    CVPixelBufferRef frame = nullptr;

    ~FrameStore() {
        Reset();
    }

    void Set(CVPixelBufferRef buffer) {
        CVPixelBufferRetain(buffer);
        std::scoped_lock lock{mutex};
        if (frame != nullptr) {
            CVPixelBufferRelease(frame);
        }
        frame = buffer;
    }

    /// Returns the newest frame with a reference the caller releases, or null.
    CVPixelBufferRef Take() {
        std::scoped_lock lock{mutex};
        if (frame != nullptr) {
            CVPixelBufferRetain(frame);
        }
        return frame;
    }

    void Reset() {
        std::scoped_lock lock{mutex};
        if (frame != nullptr) {
            CVPixelBufferRelease(frame);
            frame = nullptr;
        }
    }
};

} // Anonymous namespace

@interface AZCameraDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithStore:(std::shared_ptr<FrameStore>)store;
@end

@implementation AZCameraDelegate {
    std::shared_ptr<FrameStore> _store;
}

- (instancetype)initWithStore:(std::shared_ptr<FrameStore>)store {
    if ((self = [super init])) {
        _store = std::move(store);
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (buffer != nullptr) {
        _store->Set(buffer);
    }
}

@end

namespace Camera {

namespace {

/// Interface orientation the app is shown in, set by the app (see IOSCamera::SetOrientation).
std::atomic<int> g_video_orientation{static_cast<int>(AVCaptureVideoOrientationLandscapeRight)};

class IOSCamera final : public CameraInterface {
public:
    IOSCamera(bool front, const Service::CAM::Flip& flip)
        : front_camera{front}, store{std::make_shared<FrameStore>()},
          alive{std::make_shared<std::atomic<bool>>(true)} {
        using namespace Service::CAM;
        basic_flip_horizontal = flip == Flip::Horizontal || flip == Flip::Reverse;
        basic_flip_vertical = flip == Flip::Vertical || flip == Flip::Reverse;
        flip_horizontal = basic_flip_horizontal;
        flip_vertical = basic_flip_vertical;
    }

    ~IOSCamera() override {
        alive->store(false);
        StopCapture();
    }

    void StartCapture() override {
        if (capturing) {
            return;
        }
        capturing = true;
        const AVAuthorizationStatus status =
            [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == AVAuthorizationStatusNotDetermined) {
            // Asks the user, the capture starts once the answer is yes (unless the camera was
            // closed meanwhile).
            auto still_alive = alive;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                                       if (!still_alive->load()) {
                                           return;
                                       }
                                       if (granted) {
                                           StartSession();
                                       } else {
                                           LOG_ERROR(Service_CAM, "Camera access was denied");
                                       }
                                     }];
        } else if (status == AVAuthorizationStatusAuthorized) {
            StartSession();
        } else {
            LOG_ERROR(Service_CAM,
                      "The camera can't be used, allow it in the iOS settings of the app");
        }
    }

    void StopCapture() override {
        capturing = false;
        AVCaptureSession* running = nil;
        {
            std::scoped_lock lock{session_mutex};
            running = session;
            session = nil;
            delegate = nil;
        }
        if (running != nil) {
            // Stopping can take a while, don't block the emulation.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
              [running stopRunning];
            });
        }
        store->Reset();
    }

    void SetResolution(const Service::CAM::Resolution& resolution) override {
        width = resolution.width;
        height = resolution.height;
    }

    void SetFlip(Service::CAM::Flip flip) override {
        using namespace Service::CAM;
        flip_horizontal =
            basic_flip_horizontal ^ (flip == Flip::Horizontal || flip == Flip::Reverse);
        flip_vertical = basic_flip_vertical ^ (flip == Flip::Vertical || flip == Flip::Reverse);
    }

    void SetEffect(Service::CAM::Effect effect) override {
        this->effect = effect;
    }

    void SetFormat(Service::CAM::OutputFormat format) override {
        output_rgb = format == Service::CAM::OutputFormat::RGB565;
    }

    void SetFrameRate(Service::CAM::FrameRate) override {}

    std::vector<u16> ReceiveFrame() override;

    bool IsPreviewAvailable() override {
        return capturing;
    }

private:
    void StartSession() {
        std::scoped_lock lock{session_mutex};
        if (!capturing || session != nil) {
            return;
        }
        AVCaptureDevicePosition position =
            front_camera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        AVCaptureDevice* device =
            [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                               mediaType:AVMediaTypeVideo
                                                position:position];
        if (device == nil) {
            LOG_ERROR(Service_CAM, "No {} camera found", front_camera ? "front" : "back");
            return;
        }
        NSError* error = nil;
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                            error:&error];
        if (input == nil) {
            LOG_ERROR(Service_CAM, "Unable to open the camera: {}",
                      error ? [error.localizedDescription UTF8String] : "unknown error");
            return;
        }

        AVCaptureSession* new_session = [[AVCaptureSession alloc] init];
        // 4:3 like the 3DS cameras and cheap to convert.
        if ([new_session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            new_session.sessionPreset = AVCaptureSessionPreset640x480;
        }
        if (![new_session canAddInput:input]) {
            LOG_ERROR(Service_CAM, "Unable to use the camera as an input");
            return;
        }
        [new_session addInput:input];

        AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
        output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
        output.alwaysDiscardsLateVideoFrames = YES;
        AZCameraDelegate* new_delegate = [[AZCameraDelegate alloc] initWithStore:store];
        dispatch_queue_t queue = dispatch_queue_create("azahar.camera", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:new_delegate queue:queue];
        if (![new_session canAddOutput:output]) {
            LOG_ERROR(Service_CAM, "Unable to read frames from the camera");
            return;
        }
        [new_session addOutput:output];
        AVCaptureConnection* connection = [output connectionWithMediaType:AVMediaTypeVideo];
        if (connection.isVideoOrientationSupported) {
            connection.videoOrientation = static_cast<AVCaptureVideoOrientation>(
                g_video_orientation.load(std::memory_order_relaxed));
        }

        session = new_session;
        delegate = new_delegate;
        // Starting blocks until the camera runs.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [new_session startRunning];
        });
    }

    bool front_camera;
    std::shared_ptr<FrameStore> store;
    std::shared_ptr<std::atomic<bool>> alive;
    std::mutex session_mutex;
    AVCaptureSession* session = nil;
    AZCameraDelegate* delegate = nil;
    std::atomic<bool> capturing{false};

    u32 width = 640;
    u32 height = 480;
    bool output_rgb = false;
    std::atomic<Service::CAM::Effect> effect{Service::CAM::Effect::NoEffect};
    bool flip_horizontal = false;
    bool flip_vertical = false;
    bool basic_flip_horizontal = false;
    bool basic_flip_vertical = false;
};

/// Applies the effect a game asked the camera for (Sepia, Negative...) to a pixel in [0, 255].
/// The console's image processor is not documented, these are the usual looks of the effects.
void ApplyEffect(Service::CAM::Effect effect, float rgb[3]) {
    using Service::CAM::Effect;
    if (effect == Effect::NoEffect) {
        return;
    }
    const float luma = 0.299f * rgb[0] + 0.587f * rgb[1] + 0.114f * rgb[2];
    switch (effect) {
    case Effect::Mono:
        rgb[0] = rgb[1] = rgb[2] = luma;
        break;
    case Effect::Sepia:
        rgb[0] = luma * 1.2f;
        rgb[1] = luma * 0.95f;
        rgb[2] = luma * 0.65f;
        break;
    case Effect::Sepia01:
        rgb[0] = luma * 1.1f + 20.0f;
        rgb[1] = luma + 10.0f;
        rgb[2] = luma * 0.75f;
        break;
    case Effect::Negative:
        for (int c = 0; c < 3; c++) {
            rgb[c] = 255.0f - rgb[c];
        }
        break;
    case Effect::Negafilm:
        // A film negative: inverted with the orange cast of the film base.
        rgb[0] = 255.0f - rgb[0];
        rgb[1] = (255.0f - rgb[1]) * 0.92f;
        rgb[2] = (255.0f - rgb[2]) * 0.75f;
        break;
    default:
        break;
    }
    for (int c = 0; c < 3; c++) {
        rgb[c] = std::clamp(rgb[c], 0.0f, 255.0f);
    }
}

/// Samples a BGRA image with bilinear filtering.
struct Sampler {
    const u8* data;
    std::size_t stride;
    int width;
    int height;

    void Sample(float x, float y, float rgb[3]) const {
        x = std::clamp(x, 0.0f, static_cast<float>(width - 1));
        y = std::clamp(y, 0.0f, static_cast<float>(height - 1));
        const int x0 = static_cast<int>(x);
        const int y0 = static_cast<int>(y);
        const int x1 = std::min(x0 + 1, width - 1);
        const int y1 = std::min(y0 + 1, height - 1);
        const float fx = x - static_cast<float>(x0);
        const float fy = y - static_cast<float>(y0);
        const u8* p00 = data + y0 * stride + x0 * 4;
        const u8* p10 = data + y0 * stride + x1 * 4;
        const u8* p01 = data + y1 * stride + x0 * 4;
        const u8* p11 = data + y1 * stride + x1 * 4;
        // BGRA: channel 2 is red.
        for (int c = 0; c < 3; c++) {
            const int source = 2 - c;
            const float top = p00[source] + (p10[source] - p00[source]) * fx;
            const float bottom = p01[source] + (p11[source] - p01[source]) * fx;
            rgb[c] = top + (bottom - top) * fy;
        }
    }
};

std::vector<u16> IOSCamera::ReceiveFrame() {
    std::vector<u16> output(static_cast<std::size_t>(width) * height);
    CVPixelBufferRef frame = store->Take();
    if (frame == nullptr) {
        // No picture yet: black.
        if (!output_rgb) {
            std::fill(output.begin(), output.end(), static_cast<u16>(0x8000));
        }
        return output;
    }

    CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    const Sampler sampler{static_cast<const u8*>(CVPixelBufferGetBaseAddress(frame)),
                          CVPixelBufferGetBytesPerRow(frame),
                          static_cast<int>(CVPixelBufferGetWidth(frame)),
                          static_cast<int>(CVPixelBufferGetHeight(frame))};

    // Scale to cover the output and crop the middle, like the desktop frontend.
    const float scale = std::max(static_cast<float>(width) / static_cast<float>(sampler.width),
                                 static_cast<float>(height) / static_cast<float>(sampler.height));
    const float crop_width = static_cast<float>(width) / scale;
    const float crop_height = static_cast<float>(height) / scale;
    const float origin_x = (static_cast<float>(sampler.width) - crop_width) / 2.0f;
    const float origin_y = (static_cast<float>(sampler.height) - crop_height) / 2.0f;

    const Service::CAM::Effect current_effect = effect.load();
    const auto pixel = [&](u32 x, u32 y, float rgb[3]) {
        const u32 source_x = flip_horizontal ? width - 1 - x : x;
        const u32 source_y = flip_vertical ? height - 1 - y : y;
        sampler.Sample(origin_x + (static_cast<float>(source_x) + 0.5f) * crop_width / width - 0.5f,
                       origin_y + (static_cast<float>(source_y) + 0.5f) * crop_height / height -
                           0.5f,
                       rgb);
        ApplyEffect(current_effect, rgb);
    };

    if (output_rgb) {
        for (u32 y = 0; y < height; y++) {
            for (u32 x = 0; x < width; x++) {
                float rgb[3];
                pixel(x, y, rgb);
                const u32 r = static_cast<u32>(std::clamp(rgb[0], 0.0f, 255.0f)) >> 3;
                const u32 g = static_cast<u32>(std::clamp(rgb[1], 0.0f, 255.0f)) >> 2;
                const u32 b = static_cast<u32>(std::clamp(rgb[2], 0.0f, 255.0f)) >> 3;
                output[static_cast<std::size_t>(y) * width + x] =
                    static_cast<u16>((r << 11) | (g << 5) | b);
            }
        }
    } else {
        // YUV422, two pixels share their chroma, the inverse of the console's conversion
        // (full range ITU-R BT.601).
        const auto yuv = [](const float rgb[3], int& y, int& u, int& v) {
            y = static_cast<int>(0.299f * rgb[0] + 0.587f * rgb[1] + 0.114f * rgb[2] + 0.5f);
            u = static_cast<int>(128.0f - 0.168736f * rgb[0] - 0.331264f * rgb[1] +
                                 0.5f * rgb[2] + 0.5f);
            v = static_cast<int>(128.0f + 0.5f * rgb[0] - 0.418688f * rgb[1] -
                                 0.081312f * rgb[2] + 0.5f);
        };
        for (u32 y = 0; y < height; y++) {
            for (u32 x = 0; x + 1 < width; x += 2) {
                float rgb0[3];
                float rgb1[3];
                pixel(x, y, rgb0);
                pixel(x + 1, y, rgb1);
                int y0, u0, v0, y1, u1, v1;
                yuv(rgb0, y0, u0, v0);
                yuv(rgb1, y1, u1, v1);
                const int u = std::clamp((u0 + u1) / 2, 0, 0xFF);
                const int v = std::clamp((v0 + v1) / 2, 0, 0xFF);
                const std::size_t index = static_cast<std::size_t>(y) * width + x;
                output[index] = static_cast<u16>(std::clamp(y0, 0, 0xFF) | (u << 8));
                output[index + 1] = static_cast<u16>(std::clamp(y1, 0, 0xFF) | (v << 8));
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(frame);
    return output;
}

class IOSCameraFactory final : public CameraFactory {
public:
    std::unique_ptr<CameraInterface> Create(const std::string& config,
                                            const Service::CAM::Flip& flip) override {
        return std::make_unique<IOSCamera>(config == "front", flip);
    }
};

} // Anonymous namespace

void RegisterIOSCameraFactory() {
    RegisterFactory(IOS_CAMERA_NAME, std::make_unique<IOSCameraFactory>());
}

void SetIOSCameraOrientation(bool landscape_left) {
    g_video_orientation.store(static_cast<int>(landscape_left
                                                   ? AVCaptureVideoOrientationLandscapeLeft
                                                   : AVCaptureVideoOrientationLandscapeRight),
                              std::memory_order_relaxed);
}

} // namespace Camera
