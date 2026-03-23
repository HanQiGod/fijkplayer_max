// MIT License
//
// Copyright (c) [2019] [Befovy]
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "FijkPlayer.h"
#import "FijkHostOption.h"
#import "FijkPlugin.h"
#import "FijkQueuingEventSink.h"

#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>
#import <IJKMediaPlayer/IJKMediaPlayer.h>
#import <math.h>
#import <stdatomic.h>

@interface IJKFFMoviePlayerController (FijkIOSCompat)

@property(nonatomic, readonly) UIView *view;

- (nullable UIImage *)thumbnailImageAtCurrentTime;

@end

@interface FijkPlugin ()

- (void)onPlayingChange:(int)delta;
- (void)onPlayableChange:(int)delta;
- (void)setScreenOn:(BOOL)on;

@end

static atomic_int atomicId = 0;

@implementation FijkPlayer {
    IJKFFMoviePlayerController *_ijkMediaPlayer;
    IJKFFOptions *_ijkOptions;

    FijkQueuingEventSink *_eventSink;
    FlutterMethodChannel *_methodChannel;
    FlutterEventChannel *_eventChannel;

    id<FlutterPluginRegistrar> _registrar;

    int _width;
    int _height;
    int _rotate;

    FijkHostOption *_hostOption;
    int _state;
    int _pid;

    NSTimer *_positionTimer;
    int _loopCount;
    int _remainingLoopCount;
    BOOL _videoRenderingStarted;
    BOOL _audioRenderingStarted;
    BOOL _freezing;
}

static const int idle = 0;
static const int initialized = 1;
static const int asyncPreparing = 2;
static const int __attribute__((unused)) prepared = 3;
static const int __attribute__((unused)) started = 4;
static const int paused = 5;
static const int completed = 6;
static const int stopped = 7;
static const int error = 8;
static const int end = 9;

- (instancetype)initWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
    self = [super init];
    if (self) {
        _registrar = registrar;
        _eventSink = [[FijkQueuingEventSink alloc] init];
        _hostOption = [[FijkHostOption alloc] init];
        _ijkOptions = [IJKFFOptions optionsByDefault];
        _rotate = 0;
        _state = idle;
        _loopCount = 0;
        _remainingLoopCount = 0;

        int pid = atomic_fetch_add(&atomicId, 1);
        _playerId = @(pid);
        _pid = pid;

        [_ijkOptions setOptionIntValue:0
                                forKey:@"start-on-prepared"
                            ofCategory:kIJKFFOptionCategoryPlayer];
        [_ijkOptions setOptionIntValue:1
                                forKey:@"enable-position-notify"
                            ofCategory:kIJKFFOptionCategoryPlayer];
        [_ijkOptions setOptionIntValue:1
                                forKey:@"videotoolbox"
                            ofCategory:kIJKFFOptionCategoryPlayer];

        [IJKFFMoviePlayerController setLogLevel:k_IJK_LOG_INFO];

        _methodChannel = [FlutterMethodChannel
            methodChannelWithName:[@"befovy.com/fijkplayer_max/"
                                      stringByAppendingString:[_playerId
                                                                  stringValue]]
                  binaryMessenger:[registrar messenger]];

        __block typeof(self) weakSelf = self;
        [_methodChannel setMethodCallHandler:^(FlutterMethodCall *call,
                                               FlutterResult result) {
          [weakSelf handleMethodCall:call result:result];
        }];

        _eventChannel = [FlutterEventChannel
            eventChannelWithName:[@"befovy.com/fijkplayer_max/event/"
                                     stringByAppendingString:[_playerId
                                                                 stringValue]]
                 binaryMessenger:[registrar messenger]];

        [_eventChannel setStreamHandler:self];
    }

    return self;
}

- (void)setup {
}

- (UIView *)playerView {
    return _ijkMediaPlayer.view;
}

- (int64_t)durationMs {
    if (_ijkMediaPlayer == nil) {
        return 0;
    }
    NSTimeInterval duration = _ijkMediaPlayer.duration;
    if (!isfinite(duration) || duration < 0) {
        return 0;
    }
    return llround(duration * 1000.0);
}

- (int64_t)currentPositionMs {
    if (_ijkMediaPlayer == nil) {
        return 0;
    }
    NSTimeInterval position = _ijkMediaPlayer.currentPlaybackTime;
    if (!isfinite(position) || position < 0) {
        return 0;
    }
    return llround(position * 1000.0);
}

- (int64_t)playableDurationMs {
    if (_ijkMediaPlayer == nil) {
        return 0;
    }
    NSTimeInterval playable = _ijkMediaPlayer.playableDuration;
    if (!isfinite(playable) || playable < 0) {
        return 0;
    }
    return llround(playable * 1000.0);
}

- (void)startPositionTimerIfNeeded {
    if (_positionTimer != nil) {
        return;
    }
    _positionTimer =
        [NSTimer timerWithTimeInterval:0.25
                                 target:self
                               selector:@selector(onPositionTimer:)
                               userInfo:nil
                                repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_positionTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPositionTimer {
    [_positionTimer invalidate];
    _positionTimer = nil;
}

- (void)resetRuntimeFlags {
    _width = 0;
    _height = 0;
    _rotate = 0;
    _videoRenderingStarted = NO;
    _audioRenderingStarted = NO;
    _freezing = NO;
    _remainingLoopCount = _loopCount;
    [self stopPositionTimer];
}

- (void)addPlayerObservers {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(onPreparedNotification:)
                   name:IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onPlaybackStateNotification:)
                   name:IJKMPMoviePlayerPlaybackStateDidChangeNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onLoadStateNotification:)
                   name:IJKMPMoviePlayerLoadStateDidChangeNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onNaturalSizeNotification:)
                   name:IJKMPMovieNaturalSizeAvailableNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onVideoRenderedNotification:)
                   name:IJKMPMoviePlayerFirstVideoFrameRenderedNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onAudioRenderedNotification:)
                   name:IJKMPMoviePlayerFirstAudioFrameRenderedNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onSeekCompleteNotification:)
                   name:IJKMPMoviePlayerDidSeekCompleteNotification
                 object:_ijkMediaPlayer];
    [center addObserver:self
               selector:@selector(onPlaybackFinishedNotification:)
                   name:IJKMPMoviePlayerPlaybackDidFinishNotification
                 object:_ijkMediaPlayer];
}

- (void)removePlayerObservers {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self
                      name:IJKMPMediaPlaybackIsPreparedToPlayDidChangeNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerPlaybackStateDidChangeNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerLoadStateDidChangeNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMovieNaturalSizeAvailableNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerFirstVideoFrameRenderedNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerFirstAudioFrameRenderedNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerDidSeekCompleteNotification
                    object:_ijkMediaPlayer];
    [center removeObserver:self
                      name:IJKMPMoviePlayerPlaybackDidFinishNotification
                    object:_ijkMediaPlayer];
}

- (void)disposeMediaPlayer {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    [self stopPositionTimer];
    [self removePlayerObservers];
    [_ijkMediaPlayer shutdown];
    _ijkMediaPlayer = nil;
    [self resetRuntimeFlags];
}

- (void)createMediaPlayerWithURL:(NSString *)url {
    [self disposeMediaPlayer];

    _ijkMediaPlayer =
        [[IJKFFMoviePlayerController alloc] initWithContentURLString:url
                                                         withOptions:_ijkOptions];
    _ijkMediaPlayer.shouldShowHudView = NO;
    _ijkMediaPlayer.scalingMode = IJKMPMovieScalingModeAspectFit;
    [self addPlayerObservers];
}

- (void)shutdown {
    [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
              andArg1:end
              andArg2:_state
             andExtra:nil];

    [self disposeMediaPlayer];

    [_methodChannel setMethodCallHandler:nil];
    _methodChannel = nil;

    [_eventSink setDelegate:nil];
    _eventSink = nil;
    [_eventChannel setStreamHandler:nil];
    _eventChannel = nil;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
    [_eventSink setDelegate:nil];
    return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:
                                           (nonnull FlutterEventSink)events {
    [_eventSink setDelegate:events];
    return nil;
}

- (BOOL)isPlayable:(int)state {
    return state == started || state == paused || state == completed ||
           state == prepared;
}

- (void)emitBufferingProgress {
    if (_ijkMediaPlayer == nil) {
        return;
    }
    int64_t head = [self playableDurationMs];
    int64_t duration = [self durationMs];
    int percent = 0;
    if (duration > 0 && head > 0) {
        percent = (int)MIN(100, (head * 100) / duration);
    }
    [_eventSink success:@{
        @"event" : @"buffering",
        @"head" : @(head),
        @"percent" : @(percent),
    }];
}

- (void)emitPosition {
    if (_ijkMediaPlayer == nil) {
        return;
    }
    [_eventSink success:@{
        @"event" : @"pos",
        @"pos" : @([self currentPositionMs]),
    }];
}

- (void)onPositionTimer:(NSTimer *)timer {
    if (_ijkMediaPlayer == nil || ![self isPlayable:_state]) {
        return;
    }
    [self emitPosition];
    [self emitBufferingProgress];
}

- (void)updateVideoSize {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    CGSize size = _ijkMediaPlayer.naturalSize;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 ||
        size.height <= 0) {
        return;
    }

    int width = (int)lround(size.width);
    int height = (int)lround(size.height);
    if (width == _width && height == _height) {
        return;
    }

    _width = width;
    _height = height;
    [self handleEvent:IJKMPET_VIDEO_SIZE_CHANGED
              andArg1:width
              andArg2:height
             andExtra:nil];
}

- (int)fijkStateFromPlaybackState:(IJKMPMoviePlaybackState)playbackState {
    switch (playbackState) {
    case IJKMPMoviePlaybackStatePlaying:
        return started;
    case IJKMPMoviePlaybackStatePaused:
        return paused;
    case IJKMPMoviePlaybackStateInterrupted:
        return paused;
    case IJKMPMoviePlaybackStateSeekingForward:
    case IJKMPMoviePlaybackStateSeekingBackward:
        return started;
    case IJKMPMoviePlaybackStateStopped:
    default:
        return stopped;
    }
}

- (void)onPreparedNotification:(NSNotification *)notification {
    if (_ijkMediaPlayer == nil || !_ijkMediaPlayer.isPreparedToPlay) {
        return;
    }

    [_eventSink success:@{
        @"event" : @"prepared",
        @"duration" : @([self durationMs]),
    }];
    [self updateVideoSize];
    [self emitBufferingProgress];

    if (_state <= asyncPreparing) {
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:prepared
                  andArg2:_state
                 andExtra:nil];
    }
}

- (void)onPlaybackStateNotification:(NSNotification *)notification {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    int newState = [self fijkStateFromPlaybackState:_ijkMediaPlayer.playbackState];
    if (_state == completed && newState == stopped) {
        return;
    }
    if (newState == _state) {
        return;
    }

    [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
              andArg1:newState
              andArg2:_state
             andExtra:nil];

    if (newState == started) {
        [self startPositionTimerIfNeeded];
        [self emitPosition];
        [self emitBufferingProgress];
    } else if (newState != completed) {
        [self stopPositionTimer];
    }
}

- (void)onLoadStateNotification:(NSNotification *)notification {
    if (_ijkMediaPlayer == nil) {
        return;
    }

    BOOL freezing =
        (_ijkMediaPlayer.loadState & IJKMPMovieLoadStateStalled) ==
        IJKMPMovieLoadStateStalled;
    if (freezing != _freezing) {
        _freezing = freezing;
        [_eventSink success:@{
            @"event" : @"freeze",
            @"value" : @(freezing),
        }];
    }
    [self emitBufferingProgress];
}

- (void)onNaturalSizeNotification:(NSNotification *)notification {
    [self updateVideoSize];
}

- (void)onVideoRenderedNotification:(NSNotification *)notification {
    if (_videoRenderingStarted) {
        return;
    }
    _videoRenderingStarted = YES;
    [_eventSink success:@{
        @"event" : @"rendering_start",
        @"type" : @"video",
    }];
}

- (void)onAudioRenderedNotification:(NSNotification *)notification {
    if (_audioRenderingStarted) {
        return;
    }
    _audioRenderingStarted = YES;
    [_eventSink success:@{
        @"event" : @"rendering_start",
        @"type" : @"audio",
    }];
}

- (void)onSeekCompleteNotification:(NSNotification *)notification {
    NSNumber *err = notification.userInfo[IJKMPMoviePlayerDidSeekCompleteErrorKey];
    [self emitPosition];
    [self emitBufferingProgress];
    [_eventSink success:@{
        @"event" : @"seek_complete",
        @"pos" : @([self currentPositionMs]),
        @"err" : err ?: @(0),
    }];
}

- (void)onPlaybackFinishedNotification:(NSNotification *)notification {
    NSNumber *reason = notification.userInfo[IJKMPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    NSInteger finishReason =
        reason == nil ? IJKMPMovieFinishReasonPlaybackEnded : reason.integerValue;

    if (finishReason == IJKMPMovieFinishReasonPlaybackEnded) {
        if (_remainingLoopCount != 0) {
            if (_remainingLoopCount > 0) {
                _remainingLoopCount -= 1;
            }
            _ijkMediaPlayer.currentPlaybackTime = 0;
            [_ijkMediaPlayer play];
            return;
        }

        [self stopPositionTimer];
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:completed
                  andArg2:_state
                 andExtra:nil];
        return;
    }

    if (finishReason == IJKMPMovieFinishReasonPlaybackError) {
        _state = error;
        [_eventSink error:@"-1"
                  message:@"playback error"
                  details:reason ?: @(0)];
    }
}

- (void)onStateChangedWithNew:(int)newState andOld:(int)oldState {
    FijkPlugin *plugin = [FijkPlugin singleInstance];
    if (plugin == nil)
        return;
    if (newState == started && oldState != started) {
        [plugin onPlayingChange:1];
        if ([[_hostOption getIntValue:FIJK_HOST_OPTION_REQUEST_SCREENON
                               defalt:@(0)] intValue] == 1) {
            [plugin setScreenOn:YES];
        }
    } else if (newState != started && oldState == started) {
        [plugin onPlayingChange:-1];
        if ([[_hostOption getIntValue:FIJK_HOST_OPTION_REQUEST_SCREENON
                               defalt:@(0)] intValue] == 1) {
            [plugin setScreenOn:NO];
        }
    }

    if ([self isPlayable:newState] && ![self isPlayable:oldState]) {
        [plugin onPlayableChange:1];
    } else if (![self isPlayable:newState] && [self isPlayable:oldState]) {
        [plugin onPlayableChange:-1];
    }
}

- (void)handleEvent:(int)what
            andArg1:(int)arg1
            andArg2:(int)arg2
           andExtra:(void *)extra {
    switch (what) {
    case IJKMPET_PLAYBACK_STATE_CHANGED:
        _state = arg1;
        [_eventSink success:@{
            @"event" : @"state_change",
            @"new" : @(arg1),
            @"old" : @(arg2),
        }];
        [self onStateChangedWithNew:arg1 andOld:arg2];
        break;
    case IJKMPET_VIDEO_SIZE_CHANGED:
        if (_rotate == 0 || _rotate == 180) {
            [_eventSink success:@{
                @"event" : @"size_changed",
                @"width" : @(arg1),
                @"height" : @(arg2),
            }];
        } else if (_rotate == 90 || _rotate == 270) {
            [_eventSink success:@{
                @"event" : @"size_changed",
                @"width" : @(arg2),
                @"height" : @(arg1),
            }];
        }
        break;
    default:
        break;
    }
}

- (void)applyNumberOption:(NSNumber *)value
                  forKey:(NSString *)key
                 category:(int)category {
    if (category == 0) {
        [_hostOption setIntValue:value forKey:key];
        return;
    }

    [_ijkOptions setOptionIntValue:value.longLongValue
                            forKey:key
                        ofCategory:(IJKFFOptionCategory)category];
    if (_ijkMediaPlayer != nil) {
        [_ijkMediaPlayer setOptionIntValue:value.longLongValue
                                     forKey:key
                                 ofCategory:(IJKFFOptionCategory)category];
    }
}

- (void)applyStringOption:(NSString *)value
                   forKey:(NSString *)key
                  category:(int)category {
    if (category == 0) {
        [_hostOption setStrValue:value forKey:key];
        return;
    }

    [_ijkOptions setOptionValue:value
                         forKey:key
                     ofCategory:(IJKFFOptionCategory)category];
    if (_ijkMediaPlayer != nil) {
        [_ijkMediaPlayer setOptionValue:value
                                 forKey:key
                             ofCategory:(IJKFFOptionCategory)category];
    }
}

- (void)setOptions:(NSDictionary *)options {
    for (id cat in options) {
        NSDictionary *option = [options objectForKey:cat];
        for (NSString *key in option) {
            id optValue = [option objectForKey:key];
            if ([optValue isKindOfClass:[NSNumber class]]) {
                [self applyNumberOption:optValue forKey:key category:[cat intValue]];
            } else if ([optValue isKindOfClass:[NSString class]]) {
                [self applyStringOption:optValue forKey:key category:[cat intValue]];
            }
        }
    }
}

- (void)takeSnapshot {
    if ([[_hostOption getIntValue:FIJK_HOST_OPTION_ENABLE_SNAPSHOT defalt:@(0)] intValue] <=
        0) {
        [self->_methodChannel invokeMethod:@"_onSnapshot"
                                 arguments:@"snapshot disabled"];
        return;
    }

    UIImage *image = [_ijkMediaPlayer thumbnailImageAtCurrentTime];
    if (image != nil) {
        NSDictionary *args = @{
            @"data" : UIImageJPEGRepresentation(image, 1.0),
            @"w" : @(image.size.width),
            @"h" : @(image.size.height),
        };
        [self->_methodChannel invokeMethod:@"_onSnapshot" arguments:args];
    } else {
        [self->_methodChannel invokeMethod:@"_onSnapshot"
                                 arguments:@"snapshot error"];
    }
}

- (NSString *)resolvedMediaURLString:(NSString *)inputURL
                           registrar:(id<FlutterPluginRegistrar>)registrar
                               error:(FlutterError **)error {
    NSURL *aUrl =
        [NSURL URLWithString:[inputURL stringByAddingPercentEscapesUsingEncoding:
                                           NSUTF8StringEncoding]];
    NSString *resolvedURL = inputURL;
    BOOL file404 = NO;

    if ([@"asset" isEqualToString:aUrl.scheme]) {
        NSString *host = aUrl.host;
        NSString *asset = [host length] == 0
                              ? [registrar lookupKeyForAsset:aUrl.path]
                              : [registrar lookupKeyForAsset:aUrl.path
                                                 fromPackage:host];
        if ([asset length] > 0) {
            NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
            if ([path length] > 0) {
                resolvedURL = [[NSURL fileURLWithPath:path] absoluteString];
            }
        }
        if ([resolvedURL isEqualToString:inputURL]) {
            file404 = YES;
        }
    } else if ([@"file" isEqualToString:aUrl.scheme] || [aUrl.scheme length] == 0) {
        NSString *path = [aUrl.scheme length] == 0 ? inputURL : aUrl.path;
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        if (![fileManager fileExistsAtPath:path]) {
            file404 = YES;
        } else {
            resolvedURL = [[NSURL fileURLWithPath:path] absoluteString];
        }
    }

    if (file404) {
        if (error != nil) {
            *error = [FlutterError errorWithCode:@"-875574348"
                                         message:[@"Local File not found:"
                                                     stringByAppendingString:inputURL]
                                         details:nil];
        }
        return nil;
    }

    return resolvedURL;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {

    NSDictionary *argsMap = call.arguments;
    if ([@"setupSurface" isEqualToString:call.method]) {
        result(nil);
    } else if ([@"setOption" isEqualToString:call.method]) {
        int category = [argsMap[@"cat"] intValue];
        NSString *key = argsMap[@"key"];
        if (argsMap[@"long"] != nil) {
            [self applyNumberOption:argsMap[@"long"] forKey:key category:category];
        } else if (argsMap[@"str"] != nil) {
            [self applyStringOption:argsMap[@"str"] forKey:key category:category];
        } else {
            NSLog(@"FIJKPLAYER: error arguments for setOptions");
        }
        result(nil);
    } else if ([@"applyOptions" isEqualToString:call.method]) {
        [self setOptions:argsMap];
        result(nil);
    } else if ([@"setDataSource" isEqualToString:call.method]) {
        NSString *url = argsMap[@"url"];
        FlutterError *fileError = nil;
        NSString *resolvedURL =
            [self resolvedMediaURLString:url registrar:_registrar error:&fileError];
        if (fileError != nil) {
            result(fileError);
            return;
        }

        [self createMediaPlayerWithURL:resolvedURL];
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:initialized
                  andArg2:_state
                 andExtra:nil];
        result(nil);
    } else if ([@"prepareAsync" isEqualToString:call.method]) {
        [self setup];
        [_ijkMediaPlayer prepareToPlay];
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:asyncPreparing
                  andArg2:_state
                 andExtra:nil];
        result(nil);
    } else if ([@"start" isEqualToString:call.method]) {
        [_ijkMediaPlayer play];
        result(nil);
    } else if ([@"pause" isEqualToString:call.method]) {
        [_ijkMediaPlayer pause];
        result(nil);
    } else if ([@"stop" isEqualToString:call.method]) {
        [_ijkMediaPlayer stop];
        [self stopPositionTimer];
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:stopped
                  andArg2:_state
                 andExtra:nil];
        result(nil);
    } else if ([@"reset" isEqualToString:call.method]) {
        [self disposeMediaPlayer];
        [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                  andArg1:idle
                  andArg2:_state
                 andExtra:nil];
        result(nil);
    } else if ([@"getCurrentPosition" isEqualToString:call.method]) {
        result(@([self currentPositionMs]));
    } else if ([@"setVolume" isEqualToString:call.method]) {
        double volume = [argsMap[@"volume"] doubleValue];
        [_ijkMediaPlayer setPlaybackVolume:(float)volume];
        result(nil);
    } else if ([@"seekTo" isEqualToString:call.method]) {
        long pos = [argsMap[@"msec"] longValue];
        if (_state == completed) {
            [self handleEvent:IJKMPET_PLAYBACK_STATE_CHANGED
                      andArg1:paused
                      andArg2:_state
                     andExtra:nil];
        }
        _ijkMediaPlayer.currentPlaybackTime = ((double)pos) / 1000.0;
        result(nil);
    } else if ([@"setLoop" isEqualToString:call.method]) {
        _loopCount = [argsMap[@"loop"] intValue];
        _remainingLoopCount = _loopCount;
        result(nil);
    } else if ([@"setSpeed" isEqualToString:call.method]) {
        float speed = [argsMap[@"speed"] doubleValue];
        _ijkMediaPlayer.playbackRate = speed;
        result(nil);
    } else if ([@"snapshot" isEqualToString:call.method]) {
        [self takeSnapshot];
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end
