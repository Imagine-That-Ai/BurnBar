#import "OpenBurnBarDracoDecompressor.h"

#include <memory>

#include "draco/compression/decode.h"

static GLTFComponentType OpenBurnBarGLTFComponentTypeForDracoDataType(draco::DataType type) {
    switch (type) {
        case draco::DT_INT8:
            return GLTFComponentTypeByte;
        case draco::DT_UINT8:
            return GLTFComponentTypeUnsignedByte;
        case draco::DT_INT16:
            return GLTFComponentTypeShort;
        case draco::DT_UINT16:
            return GLTFComponentTypeUnsignedShort;
        case draco::DT_UINT32:
            return GLTFComponentTypeUnsignedInt;
        case draco::DT_FLOAT32:
            return GLTFComponentTypeFloat;
        default:
            return GLTFComponentTypeInvalid;
    }
}

static void *OpenBurnBarCopyPointAttributeData(const draco::PointCloud &pointCloud,
                                               const draco::PointAttribute &attribute,
                                               int &outSize) {
    int pointCount = pointCloud.num_points();
    draco::DataType type = attribute.data_type();
    int componentCount = attribute.num_components();
    int componentSize = draco::DataTypeLength(type);
    int elementSize = componentCount * componentSize;
    int dataSize = pointCount * elementSize;
    void *data = malloc(dataSize);
    if (data == nullptr) {
        outSize = 0;
        return nullptr;
    }

    if (attribute.is_mapping_identity()) {
        auto attributePointer = attribute.GetAddress(draco::AttributeValueIndex(0));
        ::memcpy(data, attributePointer, dataSize);
    } else {
        for (draco::PointIndex index(0); index < pointCount; ++index) {
            const draco::AttributeValueIndex valueIndex = attribute.mapped_index(index);
            void *elementPointer = static_cast<char *>(data) + index.value() * elementSize;
            attribute.GetValue(valueIndex, elementPointer);
        }
    }

    outSize = dataSize;
    return data;
}

static uint32_t *OpenBurnBarCopyUInt32IndexDataForMesh(draco::Mesh *mesh,
                                                       size_t &outIndexCount,
                                                       size_t &outIndexBufferSize) {
    size_t indexCount = mesh->num_faces() * 3;
    size_t indexBufferSize = indexCount * sizeof(uint32_t);
    uint32_t *indices = static_cast<uint32_t *>(calloc(indexCount, sizeof(uint32_t)));
    if (indices == nullptr) {
        outIndexCount = 0;
        outIndexBufferSize = 0;
        return nullptr;
    }

    for (int faceIndex = 0; faceIndex < mesh->num_faces(); ++faceIndex) {
        auto const &face = mesh->face(draco::FaceIndex(faceIndex));
        indices[faceIndex * 3 + 0] = face[0].value();
        indices[faceIndex * 3 + 1] = face[1].value();
        indices[faceIndex * 3 + 2] = face[2].value();
    }

    outIndexCount = indexCount;
    outIndexBufferSize = indexBufferSize;
    return indices;
}

@implementation OpenBurnBarDracoDecompressor

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)bufferView
                                          attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributeMap {
    const char *data = static_cast<const char *>(bufferView.buffer.data.bytes) + bufferView.offset;

    draco::DecoderBuffer buffer;
    buffer.Init(data, bufferView.length);

    auto typeOrStatus = draco::Decoder::GetEncodedGeometryType(&buffer);
    if (!typeOrStatus.ok() || typeOrStatus.value() != draco::TRIANGULAR_MESH) {
        return nil;
    }

    draco::Decoder decoder;
    auto meshOrStatus = decoder.DecodeMeshFromBuffer(&buffer);
    if (!meshOrStatus.ok()) {
        return nil;
    }

    std::unique_ptr<draco::Mesh> mesh = std::move(meshOrStatus).value();
    draco::Mesh *meshPointer = mesh.get();
    NSMutableArray<GLTFAttribute *> *attributes = [NSMutableArray arrayWithCapacity:attributeMap.count];

    __block BOOL failed = NO;
    [attributeMap enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *attributeID, BOOL *stop) {
        const draco::PointAttribute *dracoAttribute = meshPointer->GetAttributeByUniqueId(attributeID.unsignedIntValue);
        if (dracoAttribute == nullptr) {
            failed = YES;
            *stop = YES;
            return;
        }

        GLTFComponentType componentType = OpenBurnBarGLTFComponentTypeForDracoDataType(dracoAttribute->data_type());
        if (componentType == GLTFComponentTypeInvalid) {
            failed = YES;
            *stop = YES;
            return;
        }

        int attributeBufferLength = 0;
        void *attributePointer = OpenBurnBarCopyPointAttributeData(*meshPointer, *dracoAttribute, attributeBufferLength);
        if (attributePointer == nullptr || attributeBufferLength <= 0) {
            if (attributePointer != nullptr) {
                free(attributePointer);
            }
            failed = YES;
            *stop = YES;
            return;
        }

        NSData *attributeData = [NSData dataWithBytesNoCopy:attributePointer
                                                     length:attributeBufferLength
                                               freeWhenDone:YES];
        GLTFBuffer *attributeBuffer = [[GLTFBuffer alloc] initWithData:attributeData];
        GLTFBufferView *attributeBufferView = [[GLTFBufferView alloc] initWithBuffer:attributeBuffer
                                                                              length:attributeBufferLength
                                                                              offset:0
                                                                              stride:0];
        GLTFValueDimension dimension = static_cast<GLTFValueDimension>(dracoAttribute->num_components());
        BOOL normalized = dracoAttribute->normalized();
        GLTFAccessor *accessor = [[GLTFAccessor alloc] initWithBufferView:attributeBufferView
                                                                   offset:0
                                                            componentType:componentType
                                                                dimension:dimension
                                                                    count:meshPointer->num_points()
                                                               normalized:normalized];
        GLTFAttribute *attribute = [[GLTFAttribute alloc] initWithName:name accessor:accessor];
        [attributes addObject:attribute];
    }];

    if (failed || attributes.count == 0) {
        return nil;
    }

    size_t indexCount = 0;
    size_t indexBufferSize = 0;
    uint32_t *indices = OpenBurnBarCopyUInt32IndexDataForMesh(meshPointer, indexCount, indexBufferSize);
    if (indices == nullptr || indexCount == 0 || indexBufferSize == 0) {
        if (indices != nullptr) {
            free(indices);
        }
        return nil;
    }

    NSData *indexData = [NSData dataWithBytesNoCopy:indices
                                             length:indexBufferSize
                                       freeWhenDone:YES];
    GLTFBuffer *indexBuffer = [[GLTFBuffer alloc] initWithData:indexData];
    GLTFBufferView *indexBufferView = [[GLTFBufferView alloc] initWithBuffer:indexBuffer
                                                                      length:indexBufferSize
                                                                      offset:0
                                                                      stride:0];
    GLTFAccessor *indexAccessor = [[GLTFAccessor alloc] initWithBufferView:indexBufferView
                                                                    offset:0
                                                             componentType:GLTFComponentTypeUnsignedInt
                                                                 dimension:GLTFValueDimensionScalar
                                                                     count:indexCount
                                                                normalized:NO];

    return [[GLTFPrimitive alloc] initWithPrimitiveType:GLTFPrimitiveTypeTriangles
                                            attributes:attributes
                                               indices:indexAccessor];
}

@end
