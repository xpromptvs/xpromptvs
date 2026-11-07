import Foundation
import ImageIO
import CoreGraphics

/// Standard 3×3 BlurHash coefficients, encoded from a bounded, oriented sRGB thumbnail.
enum AgentBlurHash {
    private static let alphabet=Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static func base83(_ value:Int,_ count:Int)->String {
        var value=value,result=[Character](repeating:alphabet[0],count:count)
        for i in (0..<count).reversed(){result[i]=alphabet[value%83];value/=83}
        return String(result)
    }
    private static func linear(_ value:UInt8)->Double {let v=Double(value)/255;return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
    private static func srgb(_ value:Double)->Int {let v=max(0,min(1,value));return Int((v<=0.0031308 ? v*12.92:1.055*pow(v,1/2.4)-0.055)*255+0.5)}
    static func encode(_ pixels:[UInt8],width:Int,height:Int)->String? {
        guard width>0,height>0,width<=64,height<=64,pixels.count==width*height*4 else{return nil}
        let rgb=stride(from:0,to:pixels.count,by:4).map{[linear(pixels[$0]),linear(pixels[$0+1]),linear(pixels[$0+2])]}
        var factors=[[Double]]()
        for cy in 0..<3 {for cx in 0..<3 {
            var factor=[Double](repeating:0,count:3)
            for x in 0..<width {for y in 0..<height {
                let basis=(cx==0&&cy==0 ? 1.0:2.0)*cos(.pi*Double(cx*x)/Double(width))*cos(.pi*Double(cy*y)/Double(height))
                for channel in 0..<3 {factor[channel]+=basis*rgb[x+y*width][channel]}
            }}
            factors.append(factor.map{$0/Double(width*height)})
        }}
        let quantized=max(0,min(82,Int(floor((factors.dropFirst().flatMap{$0}.map{abs($0)}.max() ?? 0)*166-0.5))))
        let maximum=Double(quantized+1)/166,dc=factors[0]
        var result=base83(20,1)+base83(quantized,1)+base83((srgb(dc[0])<<16)+(srgb(dc[1])<<8)+srgb(dc[2]),4)
        for factor in factors.dropFirst(){
            let q=factor.map{v -> Int in let x=v/maximum;return max(0,min(18,Int(floor((x<0 ? -1.0:1.0)*sqrt(abs(x))*9+9.5))))}
            result+=base83(q[0]*19*19+q[1]*19+q[2],2)
        }
        return result
    }
    static func thumbnail(_ source:CGImageSource)->String? {
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:32,kCGImageSourceShouldCacheImmediately:true]
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else{return nil}
        let width=image.width,height=image.height
        var pixels=[UInt8](repeating:0,count:width*height*4)
        let drawn=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            let rect=CGRect(x:0,y:0,width:width,height:height)
            context.setFillColor(red:32/255,green:32/255,blue:32/255,alpha:1);context.fill(rect);context.draw(image,in:rect);return true
        }
        return drawn ? encode(pixels,width:width,height:height):nil
    }
}
