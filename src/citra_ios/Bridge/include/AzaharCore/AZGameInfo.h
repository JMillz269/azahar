// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Metadata of a 3DS title, read from its SMDH.
@interface AZGameInfo : NSObject

/// Reads the metadata of the title at the provided path. Returns nil if it is not a 3DS title.
- (nullable instancetype)initWithPath:(NSString*)path NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSString* path;
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly) NSString* publisher;
@property(nonatomic, readonly) NSString* regions;
@property(nonatomic, readonly) NSString* fileType;
@property(nonatomic, readonly) uint64_t programID;
@property(nonatomic, readonly) BOOL isEncrypted;
/// 48x48 RGBA8 icon pixels, nil when the title has no icon.
@property(nonatomic, readonly, nullable) NSData* iconRGBA;

@end

NS_ASSUME_NONNULL_END
