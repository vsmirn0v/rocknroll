import CoreVideo
import LiveKitWebRTC

/// Queue-confined converter for WebRTC's native CV buffers and planar VP8 output.
public final class NativeVideoPixelBuffer {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private var pixelFormat: OSType = 0
    public init() {}
    public func convert(_ frame: LKRTCVideoFrame, region: CGRect? = nil) -> CVPixelBuffer? {
        if region == nil, let native = frame.buffer as? LKRTCCVPixelBuffer,
           native.cropX == 0, native.cropY == 0,
           native.cropWidth == native.width, native.cropHeight == native.height,
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) { return native.pixelBuffer }
        let source = frame.buffer.toI420()
        let native = (frame.buffer as? LKRTCCVPixelBuffer)?.pixelBuffer
        let nativeFormat = native.map(CVPixelBufferGetPixelFormatType)
        let preservesYUV = nativeFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            nativeFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let format = preservesYUV ? nativeFormat! : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let fullWidth = Int(source.width), fullHeight = Int(source.height)
        var x = 0, y = 0, width = fullWidth, height = fullHeight
        if let region {
            guard !region.isNull, !region.isEmpty, [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
                  region.minX >= 0, region.minY >= 0, region.maxX <= 1.001, region.maxY <= 1.001 else { return nil }
            x = Int(region.minX * CGFloat(fullWidth)) / 2 * 2
            y = Int(region.minY * CGFloat(fullHeight)) / 2 * 2
            width = min(fullWidth - x, Int(region.width * CGFloat(fullWidth))) / 2 * 2
            height = min(fullHeight - y, Int(region.height * CGFloat(fullHeight))) / 2 * 2
        }
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let dimensions = CGSize(width: width, height: height)
        if pool == nil || size != dimensions || pixelFormat != format {
            size = dimensions; pixelFormat = format
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        var result: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &result) == kCVReturnSuccess, let result else { return nil }
        CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(result, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(result, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
        let srcY = source.dataY, srcU = source.dataU, srcV = source.dataV
        let srcStrideY = Int(source.strideY), srcStrideU = Int(source.strideU), srcStrideV = Int(source.strideV)
        if x == 0 && width == srcStrideY && width == yStride {
            memcpy(luma, srcY.advanced(by: y * srcStrideY), height * width)
        } else {
            for row in 0..<height {
                memcpy(luma.advanced(by: row * yStride), srcY.advanced(by: (row + y) * srcStrideY + x), width)
            }
        }
        let chromaHeight = (height + 1) / 2, chromaWidth = (width + 1) / 2
        let chromaX = x / 2, chromaY = y / 2
        let dstUV = UnsafeMutableRawPointer(uv)
        let srcRawU = UnsafeRawPointer(srcU), srcRawV = UnsafeRawPointer(srcV)
        let simdWidth = chromaWidth & ~3
        for row in 0..<chromaHeight {
            let dstRow = dstUV.advanced(by: row * uvStride)
            let rowU = srcRawU.advanced(by: (row + chromaY) * srcStrideU + chromaX)
            let rowV = srcRawV.advanced(by: (row + chromaY) * srcStrideV + chromaX)
            var col = 0
            while col < simdWidth {
                var u = UInt64(UInt32(littleEndian: rowU.loadUnaligned(fromByteOffset: col, as: UInt32.self)))
                var v = UInt64(UInt32(littleEndian: rowV.loadUnaligned(fromByteOffset: col, as: UInt32.self)))
                u = (u | (u &<< 16)) & 0x0000_FFFF_0000_FFFF
                u = (u | (u &<< 8)) & 0x00FF_00FF_00FF_00FF
                v = (v | (v &<< 16)) & 0x0000_FFFF_0000_FFFF
                v = (v | (v &<< 8)) & 0x00FF_00FF_00FF_00FF
                let interleaved = (u | (v &<< 8)).littleEndian
                dstRow.storeBytes(of: interleaved, toByteOffset: col * 2, as: UInt64.self)
                col += 4
            }
            if col < chromaWidth {
                let dstBytes = dstRow.assumingMemoryBound(to: UInt8.self)
                let bytesU = rowU.assumingMemoryBound(to: UInt8.self)
                let bytesV = rowV.assumingMemoryBound(to: UInt8.self)
                while col < chromaWidth {
                    dstBytes[col * 2] = bytesU[col]
                    dstBytes[col * 2 + 1] = bytesV[col]
                    col += 1
                }
            }
        }
        CVBufferRemoveAllAttachments(result)
        if preservesYUV, let native {
            // Cropping/scaling rearranges YUV samples without changing their range or color space.
            // Geometry and RGB attachments do not describe the newly created NV12 buffer.
            for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
                if let value = CVBufferCopyAttachment(native, key, nil) {
                    CVBufferSetAttachment(result, key, value, .shouldPropagate)
                }
            }
        } else {
            // WebRTC's generic I420 conversion uses video-range BT.601 samples.
            CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return result
    }
}
