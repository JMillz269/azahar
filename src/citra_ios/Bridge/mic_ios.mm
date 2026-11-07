// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

#include "audio_core/input.h"
#include "audio_core/input_details.h"
#include "citra_ios/Bridge/mic_ios.h"
#include "common/logging/log.h"
#include "core/core.h"

namespace AudioCore {

namespace {

/// The microphone of the device through AVAudioEngine. The 3DS asks for mono samples at a rate
/// of its own (8 to 32 kHz) in 8 or 16 bits, signed or not, so the input of the device is
/// converted to that and queued until the core reads it.
class IOSInput final : public Input {
public:
    IOSInput() = default;

    ~IOSInput() override {
        StopSampling();
    }

    void StartSampling(const InputParameters& params) override {
        if (IsSampling()) {
            return;
        }
        parameters = params;

        AVAudioEngine* new_engine = [[AVAudioEngine alloc] init];
        AVAudioInputNode* input = new_engine.inputNode;
        AVAudioFormat* input_format = [input outputFormatForBus:0];
        if (input_format.sampleRate <= 0 || input_format.channelCount == 0) {
            LOG_ERROR(Audio, "The microphone has no usable input format (is the audio session "
                             "set up for recording?)");
            return;
        }
        AVAudioFormat* target_format =
            [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                             sampleRate:params.sample_rate
                                               channels:1
                                            interleaved:YES];
        AVAudioConverter* new_converter = [[AVAudioConverter alloc] initFromFormat:input_format
                                                                          toFormat:target_format];
        if (new_converter == nil) {
            LOG_ERROR(Audio, "Unable to convert the microphone input");
            return;
        }

        const u8 sample_bytes = std::max<u8>(params.sample_size / 8, 1);
        const bool is_unsigned = params.sign == Signedness::Unsigned;
        {
            std::scoped_lock lock{mutex};
            queue.clear();
        }
        [input installTapOnBus:0
                    bufferSize:1024
                        format:input_format
                         block:^(AVAudioPCMBuffer* buffer, AVAudioTime*) {
                           Convert(new_converter, target_format, buffer, sample_bytes,
                                   is_unsigned);
                         }];
        NSError* error = nil;
        if (![new_engine startAndReturnError:&error]) {
            LOG_ERROR(Audio, "Unable to start the microphone: {}",
                      error ? [error.localizedDescription UTF8String] : "unknown error");
            [input removeTapOnBus:0];
            return;
        }
        engine = new_engine;
    }

    void StopSampling() override {
        AVAudioEngine* running = engine;
        engine = nil;
        if (running != nil) {
            [running.inputNode removeTapOnBus:0];
            [running stop];
        }
        std::scoped_lock lock{mutex};
        queue.clear();
    }

    bool IsSampling() override {
        return engine != nil;
    }

    void AdjustSampleRate(u32 sample_rate) override {
        if (!IsSampling()) {
            return;
        }
        auto new_parameters = parameters;
        new_parameters.sample_rate = sample_rate;
        StopSampling();
        StartSampling(new_parameters);
    }

    Samples Read() override {
        std::scoped_lock lock{mutex};
        Samples samples(queue.begin(), queue.end());
        queue.clear();
        return samples;
    }

private:
    void Convert(AVAudioConverter* converter, AVAudioFormat* target, AVAudioPCMBuffer* input,
                 u8 sample_bytes, bool is_unsigned) {
        const double ratio = target.sampleRate / input.format.sampleRate;
        const AVAudioFrameCount capacity =
            static_cast<AVAudioFrameCount>(input.frameLength * ratio) + 32;
        AVAudioPCMBuffer* output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target
                                                                 frameCapacity:capacity];
        __block bool supplied = false;
        NSError* error = nil;
        [converter convertToBuffer:output
                             error:&error
                withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount,
                                                   AVAudioConverterInputStatus* status) {
                  if (supplied) {
                      *status = AVAudioConverterInputStatus_NoDataNow;
                      return nil;
                  }
                  supplied = true;
                  *status = AVAudioConverterInputStatus_HaveData;
                  return input;
                }];
        if (error != nil || output.frameLength == 0 || output.int16ChannelData == nullptr) {
            return;
        }

        const s16* source = output.int16ChannelData[0];
        std::vector<u8> bytes;
        bytes.reserve(output.frameLength * sample_bytes);
        for (AVAudioFrameCount i = 0; i < output.frameLength; i++) {
            u16 value = static_cast<u16>(source[i]);
            if (is_unsigned) {
                value ^= 0x8000; // Signed to offset binary
            }
            if (sample_bytes == 1) {
                bytes.push_back(static_cast<u8>(value >> 8));
            } else {
                bytes.push_back(static_cast<u8>(value & 0xFF));
                bytes.push_back(static_cast<u8>(value >> 8));
            }
        }

        std::scoped_lock lock{mutex};
        queue.insert(queue.end(), bytes.begin(), bytes.end());
        // Keep about a second at most, the core reads regularly.
        const std::size_t limit = static_cast<std::size_t>(parameters.sample_rate) * sample_bytes;
        while (queue.size() > limit) {
            queue.pop_front();
        }
    }

    AVAudioEngine* engine = nil;
    std::mutex mutex;
    std::deque<u8> queue;
};

std::unique_ptr<Input> CreateIOSInput(Core::System&, std::string_view) {
    return std::make_unique<IOSInput>();
}

bool HasRecordPermission() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [AVAudioSession sharedInstance].recordPermission == AVAudioSessionRecordPermissionGranted;
#pragma clang diagnostic pop
}

} // Anonymous namespace

void RegisterIOSMicrophone() {
    SetCustomInputFactory(&CreateIOSInput);
    Core::System::GetInstance().RegisterMicPermissionCheck(&HasRecordPermission);
}

} // namespace AudioCore
