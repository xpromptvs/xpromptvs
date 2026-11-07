// Semantic input rectangles. Window geometry comes from admitted capture frames.
import Foundation
import CoreVideo

enum WorkspaceHitMask {
    static func make(width:Int=1280,height:Int=800,regions:[CGRect])->CVPixelBuffer? {
        guard width>0,height>0,width<=1280,height<=800 else{return nil}
        var result:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_OneComponent8,nil,&result)==kCVReturnSuccess,let result else{return nil}
        guard CVPixelBufferLockBaseAddress(result,[])==kCVReturnSuccess else{return nil}
        defer {CVPixelBufferUnlockBaseAddress(result,[])}
        guard let base=CVPixelBufferGetBaseAddress(result) else{return nil}
        let stride=CVPixelBufferGetBytesPerRow(result)
        memset(base,0,stride*height)
        let extent=CGRect(x:0,y:0,width:width,height:height)
        for region in regions {
            guard region.minX.isFinite,region.minY.isFinite,region.width.isFinite,region.height.isFinite,region.width>0,region.height>0 else{continue}
            let clipped=region.intersection(extent)
            guard !clipped.isNull,!clipped.isEmpty else{continue}
            let left=max(0,Int(floor(clipped.minX))),right=min(width,Int(ceil(clipped.maxX)))
            let top=max(0,Int(floor(clipped.minY))),bottom=min(height,Int(ceil(clipped.maxY)))
            guard right>left,bottom>top else{continue}
            for y in top..<bottom {memset(base+y*stride+left,255,right-left)}
        }
        return result
    }
}
