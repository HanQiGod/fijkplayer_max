#import <Foundation/Foundation.h>

#import <Flutter/Flutter.h>

@class FijkPlayer;

NS_ASSUME_NONNULL_BEGIN

typedef FijkPlayer *_Nullable (^FijkPlayerProvider)(NSNumber *playerId);

@interface FijkPlayerViewFactory : NSObject <FlutterPlatformViewFactory>

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger
                   playerProvider:(FijkPlayerProvider)playerProvider;

@end

NS_ASSUME_NONNULL_END
