// ============================================================================
// host_ref.c  -  Same 2D convolution on the host CPU (cross-platform reference)
//
// Runs the identical valid 2D convolution natively on your PC so you can quote
// an absolute "normal processor" number alongside the Solvyr-3 figures. Reports
// wall-clock time and throughput (MACs/s). Note the comparison is contextual,
// not apples-to-apples: a desktop CPU has GHz clocks, hardware multipliers,
// caches, superscalar/OoO execution, and an OS -- the meaningful, controlled
// comparison is software-vs-accelerator ON Solvyr-3 (see bench.c / tb_bench.v).
//
//   cc -O2 host_ref.c -o host_ref && ./host_ref
// ============================================================================
#include <stdio.h>
#include <stdint.h>
#include <time.h>

#define IMG_W 16
#define IMG_H 16
#define K     3
#define OUT_W (IMG_W - K + 1)
#define OUT_H (IMG_H - K + 1)
#define ITERS 100000               // repeat to get a measurable wall time

static int16_t img[IMG_W*IMG_H];
static int16_t krn[K*K] = { 1,0,1, 0,1,0, 1,0,1 };
static int32_t out[OUT_W*OUT_H];

static void conv(void){
    for (int oy = 0; oy < OUT_H; oy++)
        for (int ox = 0; ox < OUT_W; ox++) {
            int32_t acc = 0;
            for (int ky = 0; ky < K; ky++)
                for (int kx = 0; kx < K; kx++)
                    acc += img[(oy+ky)*IMG_W + (ox+kx)] * krn[ky*K + kx];
            out[oy*OUT_W + ox] = acc;
        }
}

int main(void){
    for (int i = 0; i < IMG_W*IMG_H; i++) img[i] = (int16_t)(i & 0x3F);

    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    volatile int32_t sink = 0;
    for (int it = 0; it < ITERS; it++) { conv(); sink ^= out[0]; }
    clock_gettime(CLOCK_MONOTONIC, &b);

    double ns = (b.tv_sec - a.tv_sec)*1e9 + (b.tv_nsec - a.tv_nsec);
    double per = ns / ITERS;
    long long macs = (long long)OUT_W*OUT_H*K*K;
    printf("host 2D conv  %dx%d (X) %dx%d -> %dx%d\n",
           IMG_W, IMG_H, K, K, OUT_W, OUT_H);
    printf("  per-conv time : %.1f ns  (%lld MACs)\n", per, macs);
    printf("  throughput    : %.1f Mmac/s\n", macs / per * 1e3);
    printf("  out[0]=%d  (checksum sink=%d)\n", out[0], sink);
    return 0;
}
