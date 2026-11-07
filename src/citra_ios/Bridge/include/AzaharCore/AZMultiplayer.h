// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AZMultiplayerState) {
    AZMultiplayerStateDisconnected = 0,
    AZMultiplayerStateConnecting = 1,
    AZMultiplayerStateJoined = 2,
    AZMultiplayerStateModerator = 3,
};

/**
 * Multiplayer rooms. Games that use local wireless (UDS) play over the room the emulator is in:
 * everybody in the room appears to be in wireless range of each other. A room is joined by its
 * address, or created on this device for others to join.
 *
 * Rooms work while a game runs, the room code needs the emulated console's identity.
 */
@interface AZMultiplayer : NSObject

@property(class, nonatomic, readonly) AZMultiplayer* shared;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) AZMultiplayerState state;
/// Whether this device hosts the room it is in.
@property(nonatomic, readonly) BOOL isHosting;
@property(nonatomic, readonly, copy) NSString* roomName;
@property(nonatomic, readonly) NSInteger maxMembers;
/// Nicknames of the members of the room, this device included.
@property(nonatomic, readonly, copy) NSArray<NSString*>* members;
/// The chat and the status messages (somebody joined...), oldest first.
@property(nonatomic, readonly, copy) NSArray<NSString*>* messages;

/// Called on the main thread whenever the state, the members or the messages changed.
@property(nonatomic, copy, nullable) void (^onChange)(void);

/// The name of the emulated console's user, to suggest as a nickname. Empty while no game runs.
@property(nonatomic, readonly, copy) NSString* suggestedNickname;

/// Whether a nickname is acceptable to a room (4 to 20 letters, digits, space . _ -).
+ (BOOL)isValidNickname:(NSString*)nickname;

/// Joins a room. The completion gets nil on success or a message saying what went wrong.
- (void)joinWithAddress:(NSString*)address
                   port:(NSInteger)port
               nickname:(NSString*)nickname
               password:(NSString*)password
             completion:(void (^)(NSString* _Nullable error))completion
    NS_SWIFT_NAME(join(address:port:nickname:password:completion:));

/// Creates a room on this device and joins it.
- (void)hostWithName:(NSString*)name
                port:(NSInteger)port
            nickname:(NSString*)nickname
            password:(NSString*)password
          maxMembers:(NSInteger)maxMembers
          completion:(void (^)(NSString* _Nullable error))completion
    NS_SWIFT_NAME(host(name:port:nickname:password:maxMembers:completion:));

- (void)sendMessage:(NSString*)message NS_SWIFT_NAME(send(message:));
/// Leaves the room, and closes it when this device hosts it.
- (void)leave;
/// Asks the room to remove a member (moderators and the host only).
- (void)kick:(NSString*)nickname;

@end

NS_ASSUME_NONNULL_END
