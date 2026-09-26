#import <Foundation/Foundation.h>
#import <GLTFKit2/GLTFKit2.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenBurnBarDracoDecompressor : NSObject <GLTFDracoMeshDecompressor>

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)bufferView
                                          attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributeMap;

@end

NS_ASSUME_NONNULL_END
