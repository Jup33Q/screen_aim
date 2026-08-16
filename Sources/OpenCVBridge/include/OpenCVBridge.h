//
//  OpenCVBridge.h
//  OpenCVBridge（ObjC++ 桥接层）— cv::aruco 检测 / 标记生成 / 单应映射的纯 ObjC API
//
//  关键约束：输入必须是紧凑（无行 padding）BGRA；标记字典固定 DICT_4X4_50；
//  检测输出为帧像素坐标（左上角原点）
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个检测到的 ArUco 标记
@interface ArucoMarker : NSObject
@property(nonatomic, assign) int markerId;
@property(nonatomic, assign) CGPoint center;   // 标记中心（帧像素坐标）
@property(nonatomic, assign) float corner0x;
@property(nonatomic, assign) float corner0y;
@end

/// OpenCV 桥接：ArUco 检测 + 单应映射
@interface OpenCVBridge : NSObject

- (instancetype)init;

/// 在紧凑 BGRA 数据上检测 ArUco 标记（DICT_4X4_50）
- (NSArray<ArucoMarker*>*)detectMarkersInBGRABuffer:(const void*)bytes
                                              width:(int)width
                                             height:(int)height;

/// 直接对图片文件做检测（用于离线自检）
- (NSArray<ArucoMarker*>*)detectMarkersInImageFile:(NSString*)path;

/// 生成一张测试场景：白底画布四角 + 四边中点共 8 个标记（id 0-7，带静区），用于自检
+ (BOOL)generateTestSceneToFile:(NSString*)path error:(NSError* _Nullable*)error;

/// 生成单个标记的 PNG 数据（内存中，用于直接贴到 NSImage）
+ (NSData* _Nullable)markerPNGWithId:(int)markerId sidePixels:(int)sidePixels;

/// 生成 n 个校准标记 PNG（id 0..n-1，边长 sidePixels）到目录，返回是否全部成功
+ (BOOL)generateMarkersToDirectory:(NSString*)dir
                             count:(int)n
                       sidePixels:(int)sidePixels
                            error:(NSError* _Nullable*)error;

/// 由 4 组对应点求单应矩阵并映射一个点。
/// src/dst 各为 4 个 CGPoint (NSValue)。失败时 ok 置 NO。
+ (CGPoint)mapPoint:(CGPoint)point
           srcPoints:(NSArray<NSValue*>*)src
           dstPoints:(NSArray<NSValue*>*)dst
             success:(BOOL* _Nullable)ok;

/// 由 ≥4 组对应点用 RANSAC 求单应并映射一个点（冗余 8 标记模式，见 ADR-007）。
/// src/dst 各 ≥4 个 CGPoint (NSValue)；内点不足 4 或求解退化时 ok 置 NO。
+ (CGPoint)mapPointRANSAC:(CGPoint)point
                srcPoints:(NSArray<NSValue*>*)src
                dstPoints:(NSArray<NSValue*>*)dst
                  success:(BOOL* _Nullable)ok;

@end

NS_ASSUME_NONNULL_END
