// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

#import <AzaharCore/AZMultiplayer.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <thread>

#include "common/logging/log.h"
#include "core/core.h"
#include "core/hle/service/cfg/cfg.h"
#include "network/network.h"
#include "network/room.h"
#include "network/room_member.h"

namespace {

NSString* ErrorText(Network::RoomMember::Error error) {
    using Error = Network::RoomMember::Error;
    switch (error) {
    case Error::LostConnection:
        return @"The connection to the room was lost.";
    case Error::HostKicked:
        return @"You were removed from the room by the host.";
    case Error::UnknownError:
        return @"The room could not be reached. Check that this app may use the local network "
               @"(iOS Settings) and that the address is right.";
    case Error::NameCollision:
        return @"Somebody in the room already uses this nickname.";
    case Error::MacCollision:
        return @"Somebody in the room already has this console address.";
    case Error::ConsoleIdCollision:
        return @"Somebody in the room has the same console ID. Games on two devices that share a "
               @"system setup cannot be in one room.";
    case Error::WrongVersion:
        return @"The room runs a different version of the emulator.";
    case Error::WrongPassword:
        return @"The password is wrong.";
    case Error::CouldNotConnect:
        return @"The room did not answer. Check the address and port, that both devices are on "
               @"the same network, and that this app may use the local network (iOS Settings).";
    case Error::RoomIsFull:
        return @"The room is full.";
    case Error::HostBanned:
        return @"You are banned from this room.";
    case Error::PermissionDenied:
        return @"You are not allowed to do that in this room.";
    case Error::NoSuchUser:
        return @"That member is not in the room.";
    }
    return @"Unknown error.";
}

NSString* StatusText(const Network::StatusMessageEntry& entry) {
    NSString* name = [NSString stringWithUTF8String:entry.nickname.c_str()] ?: @"";
    switch (entry.type) {
    case Network::IdMemberJoin:
        return [NSString stringWithFormat:@"%@ joined.", name];
    case Network::IdMemberLeave:
        return [NSString stringWithFormat:@"%@ left.", name];
    case Network::IdMemberKicked:
        return [NSString stringWithFormat:@"%@ was removed.", name];
    case Network::IdMemberBanned:
        return [NSString stringWithFormat:@"%@ was banned.", name];
    case Network::IdAddressUnbanned:
        return [NSString stringWithFormat:@"%@ was unbanned.", name];
    default:
        return @"";
    }
}

constexpr NSUInteger kMaxMessages = 200;

} // namespace

@implementation AZMultiplayer {
    std::mutex _mutex;
    BOOL _initialized;
    BOOL _isHosting;
    NSString* _roomName;
    NSMutableArray<NSString*>* _messages;
    NSArray<NSString*>* _members;
    NSInteger _maxMembers;
    /// The last error the room reported, picked up by a pending join.
    NSString* _lastError;
    std::atomic<bool> _errorSet;
    Network::RoomMember::CallbackHandle<Network::RoomMember::State> _stateHandle;
    Network::RoomMember::CallbackHandle<Network::RoomMember::Error> _errorHandle;
    Network::RoomMember::CallbackHandle<Network::ChatEntry> _chatHandle;
    Network::RoomMember::CallbackHandle<Network::StatusMessageEntry> _statusHandle;
    Network::RoomMember::CallbackHandle<Network::RoomInformation> _roomHandle;
}

+ (AZMultiplayer*)shared {
    static AZMultiplayer* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      instance = [[AZMultiplayer alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _roomName = @"";
        _messages = [NSMutableArray array];
        _members = @[];
    }
    return self;
}

+ (BOOL)isValidNickname:(NSString*)nickname {
    static NSRegularExpression* regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      regex = [NSRegularExpression regularExpressionWithPattern:@"^[ a-zA-Z0-9._-]{4,20}$"
                                                        options:0
                                                          error:nil];
    });
    return [regex numberOfMatchesInString:nickname
                                  options:0
                                    range:NSMakeRange(0, nickname.length)] == 1;
}

// MARK: State

- (AZMultiplayerState)state {
    if (!_initialized) {
        return AZMultiplayerStateDisconnected;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        switch (member->GetState()) {
        case Network::RoomMember::State::Joining:
            return AZMultiplayerStateConnecting;
        case Network::RoomMember::State::Joined:
            return AZMultiplayerStateJoined;
        case Network::RoomMember::State::Moderator:
            return AZMultiplayerStateModerator;
        default:
            break;
        }
    }
    return AZMultiplayerStateDisconnected;
}

- (BOOL)isHosting {
    return _isHosting;
}

- (NSString*)roomName {
    return _roomName;
}

- (NSInteger)maxMembers {
    return _maxMembers;
}

- (NSArray<NSString*>*)members {
    return _members;
}

- (NSArray<NSString*>*)messages {
    return [_messages copy];
}

- (NSString*)suggestedNickname {
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return @"";
    }
    return [NSString stringWithUTF8String:Service::CFG::GetUsername(system).c_str()] ?: @"";
}

- (void)notifyChange {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.onChange) {
          self.onChange();
      }
    });
}

- (void)appendMessage:(NSString*)message {
    if (message.length == 0) {
        return;
    }
    @synchronized(self) {
        [_messages addObject:message];
        if (_messages.count > kMaxMessages) {
            [_messages removeObjectsInRange:NSMakeRange(0, _messages.count - kMaxMessages)];
        }
    }
    [self notifyChange];
}

- (void)refreshMembers {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    NSString* room = @"";
    NSInteger slots = 0;
    if (auto member = Network::GetRoomMember().lock()) {
        for (const auto& info : member->GetMemberInformation()) {
            [names addObject:[NSString stringWithUTF8String:info.nickname.c_str()] ?: @""];
        }
        const auto information = member->GetRoomInformation();
        room = [NSString stringWithUTF8String:information.name.c_str()] ?: @"";
        slots = information.member_slots;
    }
    @synchronized(self) {
        _members = names;
        if (room.length > 0) {
            _roomName = room;
        }
        _maxMembers = slots;
    }
    [self notifyChange];
}

// MARK: Network

/// Starts the network library and listens to the room events, once.
- (BOOL)ensureInitialized {
    if (_initialized) {
        return YES;
    }
    if (!Network::Init()) {
        return NO;
    }
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return NO;
    }
    __weak AZMultiplayer* weak = self;
    _stateHandle = member->BindOnStateChanged([weak](const Network::RoomMember::State& state) {
        AZMultiplayer* strong = weak;
        if (state == Network::RoomMember::State::Joined ||
            state == Network::RoomMember::State::Moderator) {
            [strong appendMessage:@"Joined the room."];
        } else if (state == Network::RoomMember::State::Idle) {
            @synchronized(strong) {
                strong->_members = @[];
            }
        }
        [strong refreshMembers];
    });
    _errorHandle = member->BindOnError([weak](const Network::RoomMember::Error& error) {
        AZMultiplayer* strong = weak;
        @synchronized(strong) {
            strong->_lastError = ErrorText(error);
        }
        strong->_errorSet = true;
        [strong appendMessage:ErrorText(error)];
        [strong refreshMembers];
    });
    _chatHandle = member->BindOnChatMessageRecieved([weak](const Network::ChatEntry& chat) {
        NSString* name = [NSString stringWithUTF8String:chat.nickname.c_str()] ?: @"";
        NSString* text = [NSString stringWithUTF8String:chat.message.c_str()] ?: @"";
        [weak appendMessage:[NSString stringWithFormat:@"%@: %@", name, text]];
    });
    _statusHandle =
        member->BindOnStatusMessageReceived([weak](const Network::StatusMessageEntry& entry) {
            [weak appendMessage:StatusText(entry)];
            [weak refreshMembers];
        });
    _roomHandle = member->BindOnRoomInformationChanged(
        [weak](const Network::RoomInformation&) { [weak refreshMembers]; });
    _initialized = YES;
    return YES;
}

/// What stops a room from being joined right now, or nil.
- (NSString*)unavailableReason {
    auto& system = Core::System::GetInstance();
    if (!system.IsPoweredOn()) {
        return @"Start a game first. Rooms work while a game runs.";
    }
    if (![self ensureInitialized]) {
        return @"The network could not be started.";
    }
    if (self.state != AZMultiplayerStateDisconnected) {
        return @"You are already in a room.";
    }
    return nil;
}

/// Waits until a join that was started finished, then reports how it went.
- (NSString*)waitForJoin {
    auto member = Network::GetRoomMember().lock();
    if (!member) {
        return @"The network is not available.";
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    while (std::chrono::steady_clock::now() < deadline) {
        const auto state = member->GetState();
        if (state == Network::RoomMember::State::Joined ||
            state == Network::RoomMember::State::Moderator) {
            return nil;
        }
        if (_errorSet) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    @synchronized(self) {
        if (_lastError != nil) {
            return _lastError;
        }
    }
    if (member->GetState() == Network::RoomMember::State::Joining) {
        member->Leave();
    }
    return @"The room did not answer in time.";
}

- (void)joinWithAddress:(NSString*)address
                   port:(NSInteger)port
               nickname:(NSString*)nickname
               password:(NSString*)password
             completion:(void (^)(NSString*))completion {
    NSString* reason = [self unavailableReason];
    if (reason == nil && ![AZMultiplayer isValidNickname:nickname]) {
        reason = @"The nickname needs 4 to 20 letters, digits, spaces or . _ -";
    }
    if (reason == nil && (port < 1 || port > 65535)) {
        reason = @"The port is not valid.";
    }
    if (reason != nil) {
        completion(reason);
        return;
    }

    _errorSet = false;
    @synchronized(self) {
        _lastError = nil;
        _isHosting = NO;
    }
    NSString* host = [address copy];
    NSString* name = [nickname copy];
    NSString* secret = [password copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      auto& system = Core::System::GetInstance();
      if (auto member = Network::GetRoomMember().lock(); member && system.IsPoweredOn()) {
          member->Join(name.UTF8String, Service::CFG::GetConsoleIdHash(system), host.UTF8String,
                       static_cast<u16>(port), 0, Network::NoPreferredMac, secret.UTF8String);
      }
      NSString* error = [self waitForJoin];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    });
}

- (void)hostWithName:(NSString*)name
                port:(NSInteger)port
            nickname:(NSString*)nickname
            password:(NSString*)password
          maxMembers:(NSInteger)maxMembers
          completion:(void (^)(NSString*))completion {
    NSString* reason = [self unavailableReason];
    if (reason == nil && ![AZMultiplayer isValidNickname:nickname]) {
        reason = @"The nickname needs 4 to 20 letters, digits, spaces or . _ -";
    }
    if (reason == nil && (name.length < 3 || name.length > 20)) {
        reason = @"The room name needs 3 to 20 characters.";
    }
    if (reason == nil && (port < 1 || port > 65535)) {
        reason = @"The port is not valid.";
    }
    if (reason != nil) {
        completion(reason);
        return;
    }

    _errorSet = false;
    @synchronized(self) {
        _lastError = nil;
    }
    NSString* roomName = [name copy];
    NSString* host = [nickname copy];
    NSString* secret = [password copy];
    const NSInteger slots = MIN(MAX(maxMembers, 2), 16);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      auto& system = Core::System::GetInstance();
      auto room = Network::GetRoom().lock();
      auto member = Network::GetRoomMember().lock();
      if (!room || !member || !system.IsPoweredOn()) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(@"The network is not available.");
          });
          return;
      }
      if (!room->Create(roomName.UTF8String, "", "0.0.0.0", static_cast<u16>(port),
                        secret.UTF8String, static_cast<u32>(slots), host.UTF8String, "", 0,
                        std::make_unique<Network::VerifyUser::NullBackend>(), {})) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(@"The room could not be created. The port may be in use.");
          });
          return;
      }
      @synchronized(self) {
          self->_isHosting = YES;
          self->_roomName = roomName;
      }
      // Join the room that was just made, through the loopback address.
      member->Join(host.UTF8String, Service::CFG::GetConsoleIdHash(system), "127.0.0.1",
                   static_cast<u16>(port), 0, Network::NoPreferredMac, secret.UTF8String);
      NSString* error = [self waitForJoin];
      if (error != nil) {
          room->Destroy();
          @synchronized(self) {
              self->_isHosting = NO;
          }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    });
}

- (void)sendMessage:(NSString*)message {
    if (message.length == 0 || self.state == AZMultiplayerStateDisconnected) {
        return;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        member->SendChatMessage(message.UTF8String);
    }
}

- (void)leave {
    if (!_initialized) {
        return;
    }
    if (auto member = Network::GetRoomMember().lock()) {
        member->Leave();
    }
    if (auto room = Network::GetRoom().lock()) {
        if (room->GetState() == Network::Room::State::Open) {
            room->Destroy();
        }
    }
    @synchronized(self) {
        _isHosting = NO;
        _members = @[];
        _roomName = @"";
        [_messages removeAllObjects];
    }
    [self notifyChange];
}

- (void)kick:(NSString*)nickname {
    if (auto member = Network::GetRoomMember().lock()) {
        member->SendModerationRequest(Network::RoomMessageTypes::IdModKick, nickname.UTF8String);
    }
}

@end
