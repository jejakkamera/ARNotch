// Crest Now Playing bridge.
//
// macOS 15.4+ only answers MediaRemote "now playing" queries from Apple-signed processes, so Crest
// runs this library inside /usr/bin/perl (see MediaNowPlayingBridge.swift). It streams one JSON object
// per line on stdout whenever the system's now-playing item changes, and accepts commands on stdin:
//   toggle | play | pause | next | prev | seek <seconds>
// The process exits when stdin closes, i.e. as soon as Crest quits or crashes.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, CFDictionaryRef);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetPID getPID;
static MRGetIsPlaying getIsPlaying;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;

static dispatch_queue_t workQueue;
static BOOL emitScheduled = NO;
static NSUInteger lastArtworkHash = 0;

static void writeLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id jsonValue(id value) {
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSDate class]]) return @([(NSDate *)value timeIntervalSince1970]);
    return nil;
}

static void emitNow(void) {
    __block NSDictionary *info = nil;
    __block int pid = 0;
    __block BOOL playing = NO;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    getInfo(workQueue, ^(CFDictionaryRef dictionary) {
        info = [(__bridge NSDictionary *)dictionary copy];
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    getPID(workQueue, ^(int value) {
        pid = value;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    getIsPlaying(workQueue, ^(Boolean value) {
        playing = value;
        dispatch_group_leave(group);
    });

    dispatch_group_notify(group, workQueue, ^{
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"playing"] = @(playing);
        out[@"pid"] = @(pid);
        NSDictionary *keys = @{
            @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
            @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
            @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
            @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
            @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
            @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
            @"timestamp": @"kMRMediaRemoteNowPlayingInfoTimestamp",
        };
        for (NSString *key in keys) {
            id value = jsonValue(info[keys[key]]);
            if (value) out[key] = value;
        }
        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
            NSUInteger hash = artwork.length ^ (NSUInteger)[[artwork subdataWithRange:NSMakeRange(0, MIN(artwork.length, (NSUInteger)4096))] hash];
            out[@"artworkId"] = @(hash);
            // Only send the (large) image when it changed; Crest keeps the last one.
            if (hash != lastArtworkHash) {
                lastArtworkHash = hash;
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            }
        }
        writeLine(out);
    });
}

/// Coalesces bursts of notifications (a track change posts several) into one update.
static void scheduleEmit(void) {
    dispatch_async(workQueue, ^{
        if (emitScheduled) return;
        emitScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), workQueue, ^{
            emitScheduled = NO;
            emitNow();
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    // MRMediaRemoteCommand values: play 0, pause 1, toggle 2, next 4, previous 5.
    if ([verb isEqualToString:@"play"]) sendCommand(0, NULL);
    else if ([verb isEqualToString:@"pause"]) sendCommand(1, NULL);
    else if ([verb isEqualToString:@"toggle"]) sendCommand(2, NULL);
    else if ([verb isEqualToString:@"next"]) sendCommand(4, NULL);
    else if ([verb isEqualToString:@"prev"]) sendCommand(5, NULL);
    else if ([verb isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
    else if ([verb isEqualToString:@"refresh"]) { lastArtworkHash = 0; }
    scheduleEmit();
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length) dispatch_async(workQueue, ^{ handleCommand(line); });
        }
        exit(0); // stdin closed: Crest is gone.
    });
}

/// Entry point, called from perl. Never returns.
void crest_now_playing_run(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) { writeLine(@{ @"error": @"MediaRemote unavailable" }); exit(2); }
    getInfo = (MRGetInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (MRGetPID)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    getIsPlaying = (MRGetIsPlaying)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (MRSendCommand)dlsym(handle, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    MRRegister registerFn = (MRRegister)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPID || !getIsPlaying || !sendCommand || !registerFn) {
        writeLine(@{ @"error": @"MediaRemote symbols missing" });
        exit(3);
    }

    workQueue = dispatch_queue_create("crest.nowplaying", DISPATCH_QUEUE_SERIAL);
    registerFn(workQueue);
    for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange" ]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { scheduleEmit(); }];
    }
    readCommands();
    scheduleEmit();
    CFRunLoopRun();
}
