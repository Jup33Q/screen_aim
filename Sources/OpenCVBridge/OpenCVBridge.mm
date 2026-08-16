//
//  OpenCVBridge.mm
//  OpenCVBridge（ObjC++ 桥接层）— OpenCV 实现侧；API 契约见 include/OpenCVBridge.h
//

#import "OpenCVBridge.h"

#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/geometry/2d.hpp>
#import <opencv2/objdetect/aruco_detector.hpp>

@implementation ArucoMarker
@end

@implementation OpenCVBridge {
    cv::Ptr<cv::aruco::Dictionary> _dictionary;
    cv::Ptr<cv::aruco::ArucoDetector> _detector;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dictionary = cv::makePtr<cv::aruco::Dictionary>(
            cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50));
        cv::aruco::DetectorParameters params;
        params.cornerRefinementMethod = cv::aruco::CORNER_REFINE_SUBPIX;
        _detector = cv::makePtr<cv::aruco::ArucoDetector>(*_dictionary, params);
    }
    return self;
}

- (NSArray<ArucoMarker*>*)detectMarkersInBGRABuffer:(const void*)bytes
                                              width:(int)width
                                             height:(int)height {
    cv::Mat bgra(height, width, CV_8UC4, const_cast<void*>(bytes));
    cv::Mat gray;
    cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);

    std::vector<std::vector<cv::Point2f>> corners, rejected;
    std::vector<int> ids;
    _detector->detectMarkers(gray, corners, ids, rejected);

    NSMutableArray<ArucoMarker*>* result = [NSMutableArray arrayWithCapacity:ids.size()];
    for (size_t i = 0; i < ids.size(); i++) {
        auto& c = corners[i];
        cv::Point2f center(0, 0);
        for (auto& p : c) center += p;
        center *= 0.25f;

        ArucoMarker* m = [[ArucoMarker alloc] init];
        m.markerId = ids[i];
        m.center = CGPointMake(center.x, center.y);
        m.corner0x = c[0].x;
        m.corner0y = c[0].y;
        [result addObject:m];
    }
    return result;
}

- (NSArray<ArucoMarker*>*)detectMarkersInImageFile:(NSString*)path {
    cv::Mat img = cv::imread(path.fileSystemRepresentation, cv::IMREAD_COLOR);
    if (img.empty()) return @[];
    cv::Mat bgra;
    cv::cvtColor(img, bgra, cv::COLOR_BGR2BGRA);
    return [self detectMarkersInBGRABuffer:bgra.data width:bgra.cols height:bgra.rows];
}

+ (BOOL)generateTestSceneToFile:(NSString*)path error:(NSError* _Nullable*)error {
    auto dict = cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50);
    // 1000x800 白底画布，四角内侧 100px 处各放一个 200px 标记
    cv::Mat scene(800, 1000, CV_8UC1, cv::Scalar(255));
    const int inset = 100, side = 200;
    const cv::Point origins[4] = {
        {inset, inset}, {1000 - inset - side, inset},
        {1000 - inset - side, 800 - inset - side}, {inset, 800 - inset - side}
    };
    for (int i = 0; i < 4; i++) {
        cv::Mat marker;
        cv::aruco::generateImageMarker(dict, i, side, marker, 1);
        cv::Mat roi = scene(cv::Rect(origins[i], cv::Size(side, side)));
        marker.copyTo(roi);
    }
    if (!cv::imwrite(path.fileSystemRepresentation, scene)) {
        if (error) {
            *error = [NSError errorWithDomain:@"OpenCVBridge" code:3
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"写入失败: %@", path]}];
        }
        return false;
    }
    return true;
}

+ (NSData* _Nullable)markerPNGWithId:(int)markerId sidePixels:(int)sidePixels {
    auto dict = cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50);
    cv::Mat img;
    cv::aruco::generateImageMarker(dict, markerId, sidePixels, img, 1);
    std::vector<uchar> buf;
    if (!cv::imencode(".png", img, buf)) return nil;
    return [NSData dataWithBytes:buf.data() length:buf.size()];
}

+ (BOOL)generateMarkersToDirectory:(NSString*)dir
                             count:(int)n
                       sidePixels:(int)sidePixels
                            error:(NSError* _Nullable*)error {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    auto dict = cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50);
    for (int i = 0; i < n; i++) {
        cv::Mat img;
        cv::aruco::generateImageMarker(dict, i, sidePixels, img, 1);
        NSString* path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"marker_%d.png", i]];
        if (!cv::imwrite(path.fileSystemRepresentation, img)) {
            if (error) {
                *error = [NSError errorWithDomain:@"OpenCVBridge" code:1
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"写入失败: %@", path]}];
            }
            return false;
        }
    }
    return YES;
}

+ (CGPoint)mapPoint:(CGPoint)point
           srcPoints:(NSArray<NSValue*>*)src
           dstPoints:(NSArray<NSValue*>*)dst
             success:(BOOL* _Nullable)ok {
    if (src.count < 4 || dst.count < 4) {
        if (ok) *ok = false;
        return CGPointZero;
    }
    std::vector<cv::Point2f> s, d;
    for (NSValue* v in src) { CGPoint p = v.pointValue; s.emplace_back(p.x, p.y); }
    for (NSValue* v in dst) { CGPoint p = v.pointValue; d.emplace_back(p.x, p.y); }

    cv::Mat H = cv::getPerspectiveTransform(s, d);
    std::vector<cv::Point2f> in{cv::Point2f((float)point.x, (float)point.y)}, out;
    cv::perspectiveTransform(in, out, H);
    if (ok) *ok = true;
    return CGPointMake(out[0].x, out[0].y);
}

@end
