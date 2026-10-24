// CoreGraphics 私有 API：CGVirtualDisplay。
// 声明参考 DeskPad (github.com/Stengo/DeskPad)，并在 macOS 26.6 上用 ObjC runtime 核对过方法名。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) unsigned int width;
@property (nonatomic, readonly) unsigned int height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSArray *modes;
@property (nonatomic, readonly) unsigned int hiDPI;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
