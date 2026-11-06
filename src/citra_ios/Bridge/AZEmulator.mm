// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AzaharCore/AZConfiguration.h>
#import <AzaharCore/AZEmulator.h>
#import <Metal/Metal.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>

#include "citra_ios/Bridge/camera_ios.h"
#include "citra_ios/Bridge/emu_window_ios.h"
#include "citra_ios/Bridge/input_ios.h"
#include "common/apple_jit.h"
#include "common/common_paths.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/log.h"
#include "common/scm_rev.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/hle/service/service.h"
#include "core/loader/loader.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include "video_core/renderer_metal/renderer_metal.h"

NSErrorDomain const AZEmulatorErrorDomain = @"org.azahar-emu.AzaharCore";

namespace {

NSString* DescribeResult(Core::System::ResultStatus result, const std::string& details) {
    using ResultStatus = Core::System::ResultStatus;
    switch (result) {
    case ResultStatus::ErrorGetLoader:
    case ResultStatus::ErrorLoader:
        return @"The title could not be loaded. Make sure it is a valid, decrypted 3DS title.";
    case ResultStatus::ErrorLoader_ErrorEncrypted:
        return @"The title is encrypted. Please dump your titles from your own console "
               @"in a decrypted format.";
    case ResultStatus::ErrorLoader_ErrorInvalidFormat:
        return @"The title format is not supported.";
    case ResultStatus::ErrorLoader_ErrorGbaTitle:
        return @"GBA Virtual Console titles are not supported.";
    case ResultStatus::ErrorSystemMode:
        return @"Could not determine the system mode of the title.";
    case ResultStatus::ErrorSystemFiles:
        return @"Required system files are missing. Please set up the system files from "
               @"your own console.";
    case ResultStatus::ErrorN3DSApplication:
        return @"This title requires New 3DS mode, enable it in the settings.";
    case ResultStatus::ErrorCoreExceptionRaised:
        return @"The emulated CPU raised an exception.";
    case ResultStatus::ErrorShaderCacheCrash:
        return @"The emulator crashed while building the shader cache last time.";
    default:
        break;
    }
    if (!details.empty()) {
        return [NSString stringWithUTF8String:details.c_str()];
    }
    return [NSString
        stringWithFormat:@"Emulation failed with error %u.", static_cast<unsigned>(result)];
}

NSString* FindEntryWithLength(NSString* directory, NSUInteger length) {
    NSArray<NSString*>* contents =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    for (NSString* name in contents) {
        if (name.length == length) {
            return [directory stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

/// Looks for the TXM firmware image in the preboot volume.
bool HasTXMFirmware() {
    NSString* const firmware = @"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4";
    NSString* boot = FindEntryWithLength(@"/System/Volumes/Preboot", 36);
    NSString* image =
        boot ? FindEntryWithLength([boot stringByAppendingPathComponent:@"boot"], 96) : nil;
    if (!image) {
        image = FindEntryWithLength(@"/private/preboot", 96);
    }
    if (!image) {
        return false;
    }
    return access([image stringByAppendingPathComponent:firmware].fileSystemRepresentation, F_OK) ==
           0;
}

/// Parses the chip family and generation from the GPU name, for example "Apple A18 Pro GPU".
bool GetChip(unichar* series, NSInteger* number) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return false;
    }
    NSString* name = device.name.uppercaseString;
    NSRegularExpression* regex =
        [NSRegularExpression regularExpressionWithPattern:@"APPLE\\s+([MA])(\\d+)"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult* match = [regex firstMatchInString:name
                                                    options:0
                                                      range:NSMakeRange(0, name.length)];
    if (!match) {
        return false;
    }
    *series = [name characterAtIndex:[match rangeAtIndex:1].location];
    *number = [[name substringWithRange:[match rangeAtIndex:2]] integerValue];
    return true;
}

/**
 * Returns true if the device has the Trusted Execution Monitor. With TXM, executable memory has to
 * be mapped by the debugger (StikDebug universal JIT script), mprotect alone does not work.
 * Same detection as MeloCafe.
 */
bool DeviceHasTXM() {
    if (NSProcessInfo.processInfo.isiOSAppOnMac) {
        return false;
    }
    unichar series = 0;
    NSInteger number = 0;
    const bool has_chip = GetChip(&series, &number);
    if (@available(iOS 27, *)) {
        // Everything newer than the A12 has TXM on iOS 27.
        return !(has_chip && series == 'A') || number > 12;
    }
    const bool firmware = HasTXMFirmware();
    if (@available(iOS 26.6, *)) {
        if (!firmware) {
            return has_chip && (series == 'M' ? number >= 2 : number >= 15);
        }
    }
    return firmware;
}

/// Short version of an exception report for an alert: the thread, process and exception type at
/// the top plus the line with SP, LR and PC. The stack dump and all other registers are left out.
NSString* SummarizeException(const std::string& report) {
    NSString* text = [NSString stringWithUTF8String:report.c_str()];
    if (text == nil) {
        return @"";
    }
    const NSRange registers = [text rangeOfString:@"Registers:"];
    NSString* head =
        registers.location == NSNotFound ? text : [text substringToIndex:registers.location];
    head = [head stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"PC    0x"]) {
            NSString* trimmed =
                [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            return [NSString stringWithFormat:@"%@\n\n%@", head, trimmed];
        }
    }
    return head;
}

/// Error for a failed emulation run. For an exception in the emulated program the complete report
/// is attached (AZEmulatorErrorReport) and saved next to the log, because the log stops growing
/// once it is full and would no longer contain it.
NSError* MakeResultError(Core::System::ResultStatus result, const std::string& details) {
    NSMutableDictionary* info = [NSMutableDictionary dictionary];
    NSString* description = DescribeResult(result, details);
    if (result == Core::System::ResultStatus::ErrorCoreExceptionRaised && !details.empty()) {
        description =
            [NSString stringWithFormat:@"%@\n\n%@", description, SummarizeException(details)];
        if (NSString* report = [NSString stringWithUTF8String:details.c_str()]) {
            info[@"AZEmulatorErrorReport"] = report;
        }
        FileUtil::WriteStringToFile(
            true, FileUtil::GetUserPath(FileUtil::UserPath::LogDir) + "crash_report.txt", details);
    }
    info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:AZEmulatorErrorDomain
                               code:static_cast<NSInteger>(result)
                           userInfo:info];
}

NSError* MakeError(NSInteger code, NSString* description) {
    return [NSError errorWithDomain:AZEmulatorErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

} // Anonymous namespace

@implementation AZEmulator {
    std::unique_ptr<EmuWindow_iOS> _window;
    std::thread _thread;
    std::mutex _mutex;
    std::condition_variable _cv;
    std::atomic<bool> _stopRequested;
    std::atomic<bool> _pauseRequested;
    std::atomic<AZEmulationState> _state;
    std::atomic<double> _speed;
    std::atomic<double> _fps;
    std::atomic<double> _shaderProgress;
    std::atomic<double> _gpuMs;
    std::atomic<double> _stallMs;
    std::atomic<double> _drawsPerFrame;

    // Pending surface state, applied on the emulation thread.
    std::mutex _surfaceMutex;
    CAMetalLayer* _layer;
    CGSize _drawableSize;
    BOOL _portrait;
    std::atomic<bool> _surfaceDirty;

    NSString* _userDirectory;
}

+ (AZEmulator*)shared {
    static AZEmulator* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      instance = [[AZEmulator alloc] initPrivate];
    });
    return instance;
}

+ (BOOL)isUpscalingSupported {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      supported = Metal::IsUpscalingSupported();
    });
    return supported;
}

+ (BOOL)isJITAvailable {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    static bool has_txm = false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      has_txm = DeviceHasTXM();
      LOG_INFO(Frontend, "Trusted Execution Monitor: {}", has_txm ? "yes" : "no");
    });
    // Retried on every call, so a debugger attached after launch still enables the JIT.
    return Common::AppleJIT::Initialize(has_txm) != Common::AppleJIT::Mode::Unavailable;
#endif
}

+ (NSString*)versionString {
    return [NSString stringWithUTF8String:Common::g_build_fullname];
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _stopRequested = false;
        _pauseRequested = false;
        _state = AZEmulationStateStopped;
        _speed = 0.0;
        _fps = 0.0;
        _shaderProgress = -1.0;
        _gpuMs = 0.0;
        _stallMs = 0.0;
        _drawsPerFrame = 0.0;
        _surfaceDirty = false;
        _drawableSize = CGSizeZero;
        _userDirectory = @"";
    }
    return self;
}

- (NSString*)userDirectory {
    return _userDirectory;
}

- (AZEmulationState)state {
    return _state.load();
}

- (double)emulationSpeed {
    return _speed.load();
}

- (double)framesPerSecond {
    return _fps.load();
}

- (double)shaderBuildProgress {
    return _shaderProgress.load();
}

- (double)gpuMilliseconds {
    return _gpuMs.load();
}

- (double)stallMilliseconds {
    return _stallMs.load();
}

- (double)drawsPerFrame {
    return _drawsPerFrame.load();
}

- (void)setUpWithUserDirectory:(NSString*)directory {
    NSString* path =
        [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    _userDirectory = path;
    FileUtil::SetUserPath(std::string{path.UTF8String});
    for (const auto user_path :
         {FileUtil::UserPath::ConfigDir, FileUtil::UserPath::CacheDir, FileUtil::UserPath::SDMCDir,
          FileUtil::UserPath::NANDDir, FileUtil::UserPath::SysDataDir, FileUtil::UserPath::LogDir,
          FileUtil::UserPath::ShaderDir, FileUtil::UserPath::StatesDir,
          FileUtil::UserPath::CheatsDir, FileUtil::UserPath::LoadDir,
          FileUtil::UserPath::DumpDir}) {
        FileUtil::CreateFullPath(FileUtil::GetUserPath(user_path));
    }

    Common::Log::Initialize();
    Common::Log::SetColorConsoleBackendEnabled(false);
    Common::Log::Start();

    IOSInput::Init();
    IOSInput::BindInputProfile();

    // The core looks up every service module in lle_modules (Service::AttemptLLE uses .at()), the
    // other frontends fill it from their config. Use the HLE implementations of all modules.
    for (const auto& service_module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(service_module.name, false);
    }
    // The cameras are off until the settings say otherwise (see applyConfiguration).
    Settings::values.camera_name.fill("blank");
    Camera::RegisterIOSCameraFactory();

    // The native Metal renderer is the only hardware renderer on iOS.
    Settings::values.graphics_api = Settings::GraphicsAPI::Metal;

    LOG_INFO(Frontend, "Azahar {} for iOS, user directory: {}", Common::g_build_fullname,
             path.UTF8String);
    // Ask for executable memory as early as possible: on TXM devices the debugger provides it and
    // is detached afterwards.
    const bool jit = AZEmulator.isJITAvailable;
    LOG_INFO(Frontend, "JIT is {} ({})", jit ? "available" : "not available",
             Common::AppleJIT::GetModeName(Common::AppleJIT::GetMode()));
}

- (void)applyConfiguration:(AZConfiguration*)configuration {
    const bool jit = AZEmulator.isJITAvailable;
    auto& values = Settings::values;

    // Without a debugger attached, iOS does not allow mapping executable memory.
    values.use_cpu_jit = configuration.useCPUJIT && jit;
    values.use_shader_jit = configuration.useShaderJIT && jit;
    values.cpu_clock_percentage = static_cast<s32>(configuration.cpuClockPercentage);

    values.resolution_factor = static_cast<u32>(configuration.resolutionFactor);
    values.filter_mode = configuration.linearFiltering;
    values.texture_filter = static_cast<Settings::TextureFilter>(configuration.textureFilter);
    values.use_skip_duplicate_frames = configuration.skipDuplicateFrames;
    Metal::QualityOptions quality;
    quality.fast_math = configuration.fastShaderMath;
    quality.max_anisotropy = static_cast<int>(configuration.anisotropy);
    Metal::SetQualityOptions(quality);
    // Camera slots: 0 outer right, 1 inner, 2 outer left.
    const auto set_camera = [&](std::size_t slot, NSInteger choice) {
        values.camera_name[slot] = choice == 0 ? "blank" : Camera::IOS_CAMERA_NAME;
        values.camera_config[slot] = choice == 2 ? "front" : "back";
        values.camera_flip[slot] = 0;
    };
    set_camera(0, configuration.outerCamera);
    set_camera(1, configuration.innerCamera);
    set_camera(2, configuration.outerCamera);
    values.render_3d = static_cast<Settings::StereoRenderOption>(configuration.stereoMode);
    values.render_3d_which_display = configuration.stereoMode == 0
                                         ? Settings::StereoWhichDisplay::None
                                         : Settings::StereoWhichDisplay::PrimaryOnly;
    values.factor_3d = static_cast<u32>(std::clamp<NSInteger>(configuration.stereoDepth, 0, 100));
    values.swap_eyes_3d = configuration.swapEyes3D;
    values.async_shader_compilation = configuration.asyncShaderCompilation;
    values.use_disk_shader_cache = configuration.diskShaderCache;
    Metal::SetUpscalerMode(configuration.upscaling == 1 ? Metal::UpscalerMode::Spatial
                                                        : Metal::UpscalerMode::Off);

    values.layout_option = static_cast<Settings::LayoutOption>(configuration.layoutOption);
    values.portrait_layout_option =
        static_cast<Settings::PortraitLayoutOption>(configuration.portraitLayoutOption);
    values.swap_screen = configuration.swapScreens;
    values.upright_screen = configuration.uprightScreens;

    values.enable_audio_stretching = configuration.audioStretching;
    values.volume = configuration.volume;

    values.is_new_3ds = configuration.isNew3DS;
    values.region_value = static_cast<s32>(configuration.region);
    values.frame_limit =
        configuration.useFrameLimit ? static_cast<double>(configuration.frameLimit) : 0.0;

    values.graphics_api = Settings::GraphicsAPI::Metal;
    // Vertex shaders run on the GPU unless disabled; draws the Metal backend cannot translate
    // (geometry shaders, untranslatable programs) still fall back to the CPU per draw.
    values.use_hw_shader = configuration.useHardwareShaders;
    values.shaders_accurate_mul = configuration.accurateMultiplication;

    if (_state.load() != AZEmulationStateStopped) {
        Core::System::GetInstance().ApplySettings();
        _surfaceDirty = true;
    }
}

- (void)setRenderLayer:(CAMetalLayer*)layer {
    std::scoped_lock lock{_surfaceMutex};
    _layer = layer;
    _surfaceDirty = true;
}

- (void)setDrawableSize:(CGSize)size portrait:(BOOL)portrait {
    std::scoped_lock lock{_surfaceMutex};
    _drawableSize = size;
    _portrait = portrait;
    _surfaceDirty = true;
}

- (void)applyPendingSurfaceChanges {
    if (!_surfaceDirty.exchange(false) || !_window) {
        return;
    }
    CAMetalLayer* layer;
    CGSize size;
    BOOL portrait;
    {
        std::scoped_lock lock{_surfaceMutex};
        layer = _layer;
        size = _drawableSize;
        portrait = _portrait;
    }
    _window->OnSurfaceChanged((__bridge void*)layer, static_cast<unsigned>(size.width),
                              static_cast<unsigned>(size.height), portrait);
    if (_window->TakeSurfaceChanged()) {
        auto& system = Core::System::GetInstance();
        if (system.IsPoweredOn()) {
            system.GPU().Renderer().NotifySurfaceChanged(false);
        }
    }
}

- (BOOL)startWithPath:(NSString*)path error:(NSError**)error {
    if (_state.load() != AZEmulationStateStopped || _thread.joinable()) {
        if (error) {
            *error = MakeError(1, @"Emulation is already running.");
        }
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) {
            *error = MakeError(2, @"The selected file does not exist.");
        }
        return NO;
    }

    CAMetalLayer* layer;
    CGSize size;
    BOOL portrait;
    {
        std::scoped_lock lock{_surfaceMutex};
        layer = _layer;
        size = _drawableSize;
        portrait = _portrait;
    }
    _window =
        std::make_unique<EmuWindow_iOS>((__bridge void*)layer, static_cast<unsigned>(size.width),
                                        static_cast<unsigned>(size.height), portrait);
    _surfaceDirty = false;
    _stopRequested = false;
    _pauseRequested = false;
    _state = AZEmulationStateRunning;

    const std::string filepath{path.UTF8String};
    _thread = std::thread([self, filepath] { [self emulationThread:filepath]; });
    return YES;
}

- (void)emulationThread:(std::string)filepath {
    pthread_setname_np("EmuThread");
    // Without this iOS may run the thread on an efficiency core. Emulation is the most latency
    // sensitive work the app does.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    // An exception escaping this thread would terminate the app. Report it as an emulation error
    // instead so the user gets a message and the log records what happened.
    NSError* error = nil;
    try {
        error = [self runEmulation:filepath];
    } catch (const std::exception& e) {
        LOG_CRITICAL(Frontend, "Unhandled exception during emulation: {}", e.what());
        error = MakeError(-1, [NSString stringWithFormat:@"Emulation failed: %s", e.what()]);
    } catch (...) {
        LOG_CRITICAL(Frontend, "Unhandled unknown exception during emulation");
        error = MakeError(-1, @"Emulation failed with an unknown error.");
    }
    [self finishWithError:error];
}

/// Boots the title and runs the emulation loop. Returns the error that stopped emulation, if any.
- (NSError*)runEmulation:(const std::string&)filepath {
    Core::System& system = Core::System::GetInstance();

    u64 program_id{};
    FileUtil::SetCurrentRomPath(filepath);
    auto app_loader = Loader::GetLoader(filepath);
    if (app_loader) {
        app_loader->ReadProgramId(program_id);
        system.RegisterAppLoaderEarly(app_loader);
    }

    system.ApplySettings();
    Settings::LogSettings();
    Frontend::RegisterDefaultApplets(system);
    [self registerApplets];
    IOSInput::BindInputProfile();

    const Core::System::ResultStatus load_result = system.Load(*_window, filepath);
    if (load_result != Core::System::ResultStatus::Success) {
        return MakeResultError(load_result, system.GetStatusDetails());
    }

    system.GPU().ApplyPerProgramSettings(program_id);
    // Builds the shaders cached by earlier runs of this game, reporting the progress to the UI.
    system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(
        _stopRequested, [self](VideoCore::LoadCallbackStage stage, std::size_t value,
                               std::size_t total, const std::string&) {
            if (stage == VideoCore::LoadCallbackStage::Build && total > 0) {
                self->_shaderProgress = static_cast<double>(value) / static_cast<double>(total);
            } else if (stage == VideoCore::LoadCallbackStage::Complete) {
                self->_shaderProgress = -1.0;
            }
        });
    _shaderProgress = -1.0;
    system.RegisterCoreLoopThreadId();

    NSError* error = nil;
    // The performance counters only update when they are collected, which resets them. Collect
    // them once per second of wall time and publish the result.
    using StatsClock = std::chrono::steady_clock;
    auto last_stats_time = StatsClock::now();
    while (!_stopRequested) {
        [self applyPendingSurfaceChanges];

        if (_pauseRequested) {
            _state = AZEmulationStatePaused;
            const float volume = Settings::values.volume.GetValue();
            Settings::values.volume = 0;
            {
                std::unique_lock lock{_mutex};
                _cv.wait(lock, [self] { return !_pauseRequested || _stopRequested; });
            }
            Settings::values.volume = volume;
            if (_stopRequested) {
                break;
            }
            _state = AZEmulationStateRunning;
            // Do not count the time spent paused in the speed.
            [[maybe_unused]] const auto discarded = system.GetAndResetPerfStats();
            last_stats_time = StatsClock::now();
        }

        const auto result = system.RunLoop();
        if (result == Core::System::ResultStatus::ShutdownRequested) {
            break;
        }
        if (result == Core::System::ResultStatus::ErrorSavestate ||
            result == Core::System::ResultStatus::ErrorSavestateBuildMismatch) {
            // A failed save state must not end the game, tell the user and keep running.
            NSString* message =
                result == Core::System::ResultStatus::ErrorSavestateBuildMismatch
                    ? [NSString stringWithFormat:@"This state was saved by another version of "
                                                 @"Azahar (%s) and can't be loaded.",
                                                 system.GetStatusDetails().c_str()]
                    : [NSString stringWithFormat:@"The state operation failed: %s",
                                                 system.GetStatusDetails().c_str()];
            dispatch_async(dispatch_get_main_queue(), ^{
              if (self.onNotice) {
                  self.onNotice(@"Save State", message);
              }
            });
            continue;
        }
        if (result != Core::System::ResultStatus::Success) {
            error = MakeResultError(result, system.GetStatusDetails());
            break;
        }

        const auto now = StatsClock::now();
        if (now - last_stats_time >= std::chrono::seconds(1)) {
            last_stats_time = now;
            const auto stats = system.GetAndResetPerfStats();
            _speed = stats.emulation_speed * 100.0;
            _fps = stats.game_fps;
            const auto gpu = Metal::TakeFrameStats();
            if (gpu.frames > 0) {
                _gpuMs = gpu.gpu_ms;
                _stallMs = gpu.stall_ms;
                _drawsPerFrame = gpu.draws;
                LOG_INFO(Frontend,
                         "Speed {:.0f}%, {:.1f} fps: GPU {:.1f} ms (presenting {:.1f}), CPU waited "
                         "{:.1f} ms in {:.1f} stalls, {:.0f} draws, {:.1f} skipped, {:.1f} render passes, "
                         "{:.1f} blit passes, {:.1f} feedback copies, drawable wait {:.1f} ms "
                         "per frame",
                         _speed.load(), _fps.load(), gpu.gpu_ms, gpu.present_ms, gpu.stall_ms,
                         gpu.stalls,
                         gpu.draws, gpu.skipped, gpu.render_passes, gpu.blit_passes,
                         gpu.feedback_copies, gpu.drawable_ms);
            }
        }
    }
    return error;
}

- (void)finishWithError:(NSError*)error {
    Settings::ResetTemporaryFrameLimit();
    Core::System::GetInstance().Shutdown();
    _speed = 0.0;
    _fps = 0.0;
    _state = AZEmulationStateStopped;

    const bool requested = _stopRequested.load();
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_thread.joinable() && !requested) {
          self->_thread.join();
      }
      self->_window.reset();
      if (!requested && self.onStopped) {
          self.onStopped(error);
      }
    });
}

- (void)pause {
    if (_state.load() == AZEmulationStateRunning) {
        _pauseRequested = true;
    }
}

- (void)resume {
    {
        std::scoped_lock lock{_mutex};
        _pauseRequested = false;
    }
    _cv.notify_all();
}

- (void)stop {
    {
        std::scoped_lock lock{_mutex};
        _stopRequested = true;
        _pauseRequested = false;
    }
    _cv.notify_all();
    // The emulation thread may be waiting for a Mii to be chosen.
    [self cancelPendingApplets];
    if (_thread.joinable()) {
        _thread.join();
    }
    _window.reset();
}

- (void)setButton:(AZButton)button pressed:(BOOL)pressed {
    IOSInput::SetButton(static_cast<int>(button), pressed);
}

- (void)setAnalog:(AZAnalog)analog x:(float)x y:(float)y {
    IOSInput::SetAnalog(static_cast<int>(analog), x, y);
}

- (void)touchBeganAtPoint:(CGPoint)point {
    if (_window) {
        _window->OnTouchPressed(static_cast<unsigned>(std::max(point.x, 0.0)),
                                static_cast<unsigned>(std::max(point.y, 0.0)));
    }
}

- (void)touchMovedToPoint:(CGPoint)point {
    if (_window) {
        _window->OnTouchMoved(static_cast<unsigned>(std::max(point.x, 0.0)),
                              static_cast<unsigned>(std::max(point.y, 0.0)));
    }
}

- (void)touchEnded {
    if (_window) {
        _window->OnTouchReleased();
    }
}

- (void)setMotionAccelerationX:(float)ax
                             y:(float)ay
                             z:(float)az
                         gyroX:(float)gx
                         gyroY:(float)gy
                         gyroZ:(float)gz {
    IOSInput::SetMotion(ax, ay, az, gx, gy, gz);
}

@end
