#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import "RdevWorkspacePacking.h"
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
// CGWindowListCreate uses raw CGWindowID entries, not CFNumber objects.
uint8_t RdevWorkspaceWindowSize(uint32_t windowID,double *width,double *height) {
    const void *rawID=(const void *)(uintptr_t)windowID;
    CFArrayRef ids=CFArrayCreate(NULL,&rawID,1,NULL);
    CFArrayRef descriptions=CGWindowListCreateDescriptionFromArray(ids);CFRelease(ids);
    if(!descriptions)return 0;
    BOOL found=NO;
    for(NSDictionary *info in (__bridge NSArray *)descriptions) {
        if([info[(id)kCGWindowNumber] unsignedIntValue]!=windowID)continue;
        CGRect bounds;
        NSDictionary *box=info[(id)kCGWindowBounds];
        if([box isKindOfClass:NSDictionary.class] && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)box,&bounds)) {
            *width=bounds.size.width;*height=bounds.size.height;found=YES;break;
        }
    }
    CFRelease(descriptions);return found;
}

// One native round trip for the exact retained-frame request set.
void RdevWorkspaceWindowSizes(const uint32_t *windowIDs,uint32_t count,double *widths,double *heights,uint8_t *found) {
    for(uint32_t i=0;i<count;i++){found[i]=0;widths[i]=0;heights[i]=0;}
    if(!count)return;
    const void **rawIDs=calloc(count,sizeof(void *));if(!rawIDs)return;
    for(uint32_t i=0;i<count;i++)rawIDs[i]=(const void *)(uintptr_t)windowIDs[i];
    CFArrayRef ids=CFArrayCreate(NULL,rawIDs,count,NULL);free(rawIDs);
    if(!ids)return;
    CFArrayRef descriptions=CGWindowListCreateDescriptionFromArray(ids);CFRelease(ids);
    if(!descriptions)return;
    for(NSDictionary *info in (__bridge NSArray *)descriptions) {
        uint32_t windowID=[info[(id)kCGWindowNumber] unsignedIntValue];
        NSDictionary *box=info[(id)kCGWindowBounds];CGRect bounds;
        if(![box isKindOfClass:NSDictionary.class] || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)box,&bounds))continue;
        for(uint32_t i=0;i<count;i++)if(windowIDs[i]==windowID){widths[i]=bounds.size.width;heights[i]=bounds.size.height;found[i]=1;}
    }
    CFRelease(descriptions);
}

uint8_t RdevWorkspacePackingOptimized(void) {
#if defined(__OPTIMIZE__)
    return 1;
#else
    return 0;
#endif
}
static CVPixelBufferRef packRdevWorkspace(CVPixelBufferRef source, CVPixelBufferRef mask, double *timings, BOOL vectorized) {
    size_t w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source),panels=mask?3:2;
    if(CVPixelBufferGetPixelFormatType(source)!=kCVPixelFormatType_32BGRA || CVPixelBufferIsPlanar(source))return NULL;
    if(mask && (w>1280 || h>800 || CVPixelBufferGetWidth(mask)!=w || CVPixelBufferGetHeight(mask)!=h || CVPixelBufferGetPixelFormatType(mask)!=kCVPixelFormatType_OneComponent8))return NULL;
    double marks[7];if(timings)marks[0]=CFAbsoluteTimeGetCurrent();
    CVPixelBufferRef result=NULL;
    if(CVPixelBufferCreate(NULL,w*panels,h,kCVPixelFormatType_32BGRA,NULL,&result)!=kCVReturnSuccess)return NULL;
    if(timings)marks[1]=CFAbsoluteTimeGetCurrent();
    if(CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){CVPixelBufferRelease(result);return NULL;}
    if(timings)marks[2]=CFAbsoluteTimeGetCurrent();
    if(CVPixelBufferLockBaseAddress(result,0)!=kCVReturnSuccess){CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(result);return NULL;}
    if(timings)marks[3]=CFAbsoluteTimeGetCurrent();
    if(mask && CVPixelBufferLockBaseAddress(mask,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess){CVPixelBufferUnlockBaseAddress(result,0);CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(result);return NULL;}
    if(timings)marks[4]=CFAbsoluteTimeGetCurrent();
    const uint8_t *src=CVPixelBufferGetBaseAddress(source),*hit=mask?CVPixelBufferGetBaseAddress(mask):NULL;
    uint8_t *dst=CVPixelBufferGetBaseAddress(result);
    size_t ss=CVPixelBufferGetBytesPerRow(source),ds=CVPixelBufferGetBytesPerRow(result),ms=mask?CVPixelBufferGetBytesPerRow(mask):0;
    if(!src || !dst || (mask && !hit) || ss<w*4 || ds<w*panels*4 || (mask && ms<w)) {
        if(mask)CVPixelBufferUnlockBaseAddress(mask,kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(result,0);CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(result);return NULL;
    }
    for(size_t y=0;y<h;y++) {
        size_t x=0;
#if defined(__aarch64__)
        if(vectorized)for(;x+16<=w;x+=16) {
            uint8x16x4_t color=vld4q_u8(src+y*ss+x*4);
            uint8x16_t alpha=color.val[3],opaque=vdupq_n_u8(255);
            color.val[3]=opaque;
            uint8_t *rgb=dst+y*ds+x*4;
            vst4q_u8(rgb,color);
            uint8x16x4_t gray={{alpha,alpha,alpha,opaque}};
            vst4q_u8(rgb+w*4,gray);
            if(mask){uint8x16_t m=vld1q_u8(hit+y*ms+x);gray.val[0]=gray.val[1]=gray.val[2]=m;vst4q_u8(rgb+w*8,gray);}
        }
#endif
        for(;x<w;x++) {
        const uint8_t *s=src+y*ss+x*4;uint8_t *rgb=dst+y*ds+x*4,*a=rgb+w*4;
        rgb[0]=s[0];rgb[1]=s[1];rgb[2]=s[2];rgb[3]=255;
        a[0]=a[1]=a[2]=s[3];a[3]=255;
        if(mask){uint8_t *m=a+w*4;m[0]=m[1]=m[2]=hit[y*ms+x];m[3]=255;}
    }
    }
    if(timings)marks[5]=CFAbsoluteTimeGetCurrent();
    if(mask)CVPixelBufferUnlockBaseAddress(mask,kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(result,0);CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
    if(timings){marks[6]=CFAbsoluteTimeGetCurrent();for(int i=0;i<6;i++)timings[i]=(marks[i+1]-marks[i])*1000;}
    return result;
}
uint64_t RdevWorkspaceAlphaSignature(CVPixelBufferRef source) {
    if(CVPixelBufferGetPixelFormatType(source)!=kCVPixelFormatType_32BGRA)return 0;
    if(CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return 0;
    const uint8_t *base=CVPixelBufferGetBaseAddress(source);
    if(!base){CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);return 0;}
    size_t stride=CVPixelBufferGetBytesPerRow(source),width=CVPixelBufferGetWidth(source),height=CVPixelBufferGetHeight(source);
    uint64_t hash=14695981039346656037ULL;
    for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++) {
        hash ^= base[y*stride+x*4+3];hash *= 1099511628211ULL;
    }
    CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);return hash ? hash : 1;
}
CVPixelBufferRef RdevWorkspacePackAlpha(CVPixelBufferRef source){return packRdevWorkspace(source,NULL,NULL,NO);}
CVPixelBufferRef RdevWorkspacePackWithHit(CVPixelBufferRef source,CVPixelBufferRef mask){return packRdevWorkspace(source,mask,NULL,NO);}

CVPixelBufferRef RdevWorkspacePackProfiled(CVPixelBufferRef source,CVPixelBufferRef mask,double *timings){return packRdevWorkspace(source,mask,timings,NO);}

CVPixelBufferRef RdevWorkspacePackVectorizedProfiled(CVPixelBufferRef source,CVPixelBufferRef mask,double *timings){
#if defined(__aarch64__)
    return packRdevWorkspace(source,mask,timings,YES);
#else
    return NULL; // Do not label a scalar fallback as NEON.
#endif
}
CVPixelBufferRef RdevWorkspacePackVectorized(CVPixelBufferRef source,CVPixelBufferRef mask){return RdevWorkspacePackVectorizedProfiled(source,mask,NULL);}

