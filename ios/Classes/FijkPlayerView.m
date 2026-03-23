#import "FijkPlayerView.h"

#import "FijkPlayer.h"

#import <UIKit/UIKit.h>

@interface FijkPlayerContainerView : UIView

- (void)attachPlayerView:(nullable UIView *)playerView;

@end

@implementation FijkPlayerContainerView {
    __weak UIView *_attachedPlayerView;
}

- (void)attachPlayerView:(UIView *)playerView {
    if (playerView == nil || _attachedPlayerView == playerView) {
        return;
    }

    [_attachedPlayerView removeFromSuperview];
    _attachedPlayerView = playerView;
    [playerView removeFromSuperview];
    playerView.frame = self.bounds;
    playerView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:playerView];
}

@end

@interface FijkPlayerPlatformView : NSObject <FlutterPlatformView>

- (instancetype)initWithFrame:(CGRect)frame
                   playerView:(nullable UIView *)playerView;

@end

@implementation FijkPlayerPlatformView {
    FijkPlayerContainerView *_containerView;
}

- (instancetype)initWithFrame:(CGRect)frame
                   playerView:(UIView *)playerView {
    self = [super init];
    if (self) {
        _containerView = [[FijkPlayerContainerView alloc] initWithFrame:frame];
        _containerView.backgroundColor = UIColor.clearColor;
        [_containerView attachPlayerView:playerView];
    }
    return self;
}

- (UIView *)view {
    return _containerView;
}

@end

@implementation FijkPlayerViewFactory {
    NSObject<FlutterBinaryMessenger> *_messenger;
    FijkPlayerProvider _playerProvider;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger
                   playerProvider:(FijkPlayerProvider)playerProvider {
    self = [super init];
    if (self) {
        _messenger = messenger;
        _playerProvider = [playerProvider copy];
    }
    return self;
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id)args {
    NSDictionary *map = [args isKindOfClass:[NSDictionary class]] ? args : nil;
    NSNumber *playerId = [map objectForKey:@"pid"];
    FijkPlayer *player = playerId == nil ? nil : _playerProvider(playerId);
    return [[FijkPlayerPlatformView alloc] initWithFrame:frame
                                              playerView:[player playerView]];
}

@end
