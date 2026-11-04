// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AzaharCore/AZGameInfo.h>

#include <cstring>
#include <memory>
#include <vector>
#include "common/string_util.h"
#include "core/loader/loader.h"
#include "core/loader/smdh.h"

namespace {

NSString* ToNSString(const std::u16string& str) {
    NSString* result = [NSString stringWithUTF8String:Common::UTF16ToUTF8(str).c_str()];
    return result ?: @"";
}

NSString* RegionsString(const Loader::SMDH& smdh) {
    using GameRegion = Loader::SMDH::GameRegion;
    const auto regions = smdh.GetRegions();
    if (regions.empty()) {
        return @"Invalid region";
    }
    if (regions.size() >= 7) {
        return @"Region free";
    }
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (const auto region : regions) {
        switch (region) {
        case GameRegion::Japan:
            [names addObject:@"Japan"];
            break;
        case GameRegion::NorthAmerica:
            [names addObject:@"North America"];
            break;
        case GameRegion::Europe:
            [names addObject:@"Europe"];
            break;
        case GameRegion::Australia:
            [names addObject:@"Australia"];
            break;
        case GameRegion::China:
            [names addObject:@"China"];
            break;
        case GameRegion::Korea:
            [names addObject:@"Korea"];
            break;
        case GameRegion::Taiwan:
            [names addObject:@"Taiwan"];
            break;
        default:
            break;
        }
    }
    return [names componentsJoinedByString:@", "];
}

} // Anonymous namespace

@implementation AZGameInfo

- (nullable instancetype)initWithPath:(NSString*)path {
    if (!(self = [super init])) {
        return nil;
    }

    const std::string filepath{path.UTF8String};
    std::unique_ptr<Loader::AppLoader> loader = Loader::GetLoader(filepath);
    if (!loader) {
        return nil;
    }

    u64 program_id = 0;
    Loader::ResultStatus result = loader->ReadProgramId(program_id);
    if (result == Loader::ResultStatus::ErrorNotImplemented) {
        // This can happen for 3DSX and ELF files.
        program_id = 0;
        result = Loader::ResultStatus::Success;
    }
    if (result != Loader::ResultStatus::Success && result != Loader::ResultStatus::ErrorEncrypted) {
        return nil;
    }

    _path = [path copy];
    _programID = program_id;
    _isEncrypted = result == Loader::ResultStatus::ErrorEncrypted;
    _fileType = [NSString stringWithUTF8String:Loader::GetFileTypeString(loader->GetFileType(),
                                                                         loader->IsFileCompressed(),
                                                                         loader->IsFileBundle())]
                    ?: @"";

    std::vector<u8> smdh_data;
    const auto icon_result = loader->ReadIcon(smdh_data, true);
    if (icon_result == Loader::ResultStatus::ErrorEncrypted) {
        _isEncrypted = YES;
    }

    Loader::SMDH smdh{};
    const bool has_smdh = icon_result == Loader::ResultStatus::Success &&
                          smdh_data.size() >= sizeof(Loader::SMDH) &&
                          Loader::IsValidSMDH(smdh_data);
    if (has_smdh) {
        std::memcpy(&smdh, smdh_data.data(), sizeof(Loader::SMDH));
    }

    if (has_smdh) {
        constexpr auto language = Loader::SMDH::TitleLanguage::English;
        const auto& titles = smdh.titles[static_cast<std::size_t>(language)];
        std::u16string long_title{reinterpret_cast<const char16_t*>(titles.long_title.data())};
        std::u16string publisher{reinterpret_cast<const char16_t*>(titles.publisher.data())};
        _title = ToNSString(long_title);
        _publisher = ToNSString(publisher);
        _regions = RegionsString(smdh);

        // Convert the 48x48 RGB565 icon to RGBA8.
        const std::vector<u16> icon = smdh.GetIcon(true);
        if (icon.size() == 48 * 48) {
            NSMutableData* rgba = [NSMutableData dataWithLength:48 * 48 * 4];
            u8* out = static_cast<u8*>(rgba.mutableBytes);
            for (std::size_t i = 0; i < icon.size(); i++) {
                const u16 pixel = icon[i];
                const u8 r = (pixel >> 11) & 0x1F;
                const u8 g = (pixel >> 5) & 0x3F;
                const u8 b = pixel & 0x1F;
                out[i * 4 + 0] = static_cast<u8>((r << 3) | (r >> 2));
                out[i * 4 + 1] = static_cast<u8>((g << 2) | (g >> 4));
                out[i * 4 + 2] = static_cast<u8>((b << 3) | (b >> 2));
                out[i * 4 + 3] = 0xFF;
            }
            _iconRGBA = rgba;
        }
    }

    if (_title.length == 0) {
        _title = path.lastPathComponent.stringByDeletingPathExtension;
    }
    if (!_publisher) {
        _publisher = @"";
    }
    if (!_regions) {
        _regions = @"";
    }
    return self;
}

@end
