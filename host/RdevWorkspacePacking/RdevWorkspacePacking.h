#import <CoreVideo/CoreVideo.h>
// Left: captured premultiplied color. Right: alpha encoded as grayscale RGB.
CVPixelBufferRef _Nullable RdevWorkspacePackAlpha(CVPixelBufferRef _Nonnull source) CF_RETURNS_RETAINED;

// Three panels: premultiplied color, grayscale alpha, grayscale semantic hit mask.
CVPixelBufferRef _Nullable RdevWorkspacePackWithHit(CVPixelBufferRef _Nonnull source, CVPixelBufferRef _Nonnull hitMask) CF_RETURNS_RETAINED;

// Non-cryptographic cache key for visual shadows; ignores RGB. Zero means unavailable.
uint64_t RdevWorkspaceAlphaSignature(CVPixelBufferRef _Nonnull source);

// Six phase durations (ms): allocation, source lock, output lock, mask lock, copy, unlock.
CVPixelBufferRef _Nullable RdevWorkspacePackProfiled(CVPixelBufferRef _Nonnull source, CVPixelBufferRef _Nonnull hitMask, double * _Nonnull timings) CF_RETURNS_RETAINED;

// Compiler-derived, not inferred from BUILD copts (fastbuild can append -O0).
uint8_t RdevWorkspacePackingOptimized(void);

CVPixelBufferRef _Nullable RdevWorkspacePackVectorized(CVPixelBufferRef _Nonnull source, CVPixelBufferRef _Nullable hitMask) CF_RETURNS_RETAINED;

CVPixelBufferRef _Nullable RdevWorkspacePackVectorizedProfiled(CVPixelBufferRef _Nonnull source, CVPixelBufferRef _Nullable hitMask, double * _Nullable timings) CF_RETURNS_RETAINED;

// Targeted native geometry query; returns false for unavailable identity.
uint8_t RdevWorkspaceWindowSize(uint32_t windowID, double * _Nonnull width, double * _Nonnull height);

void RdevWorkspaceWindowSizes(const uint32_t * _Nonnull ids, uint32_t count, double * _Nonnull widths, double * _Nonnull heights, uint8_t * _Nonnull found);
