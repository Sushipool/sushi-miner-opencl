/**
MIT License

Copyright (c) 2016 Ondrej Mosnáček

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/*
* Argon2d
* refined version of https://gitlab.com/omos/argon2-gpu
*/
#define ARGON2_BLOCK_SIZE 1024
#define ARGON2_QWORDS_IN_BLOCK (ARGON2_BLOCK_SIZE / 8)
#define MEMORY_COST 512

#define THREADS_PER_LANE 32


inline ulong u64_build(uint hi, uint lo)
{
    return upsample(hi, lo);
}

inline uint u64_lo(ulong x)
{
    return (uint)x;
}

inline uint u64_hi(ulong x)
{
    return (uint)(x >> 32);
}

struct block_g
{
    ulong data[ARGON2_QWORDS_IN_BLOCK];
};

struct block_th
{
    ulong a, b, c, d;
};

#define ROUND1_IDX(x) (((thread & 0x1c) << 2) | (x << 2) | (thread & 0x3))
#define ROUND2_IDX(x) (((thread & 0x1c) << 2) | (x << 2) | ((thread + x) & 0x3))
#define ROUND3_IDX(x) ((x << 5) | ((thread & 0x2) << 3) | ((thread & 0x1c) >> 1) | (thread & 0x1))
#define ROUND4_IDX(x) ((x << 5) | (((thread + x) & 0x2) << 3) | ((thread & 0x1c) >> 1) | ((thread + x) & 0x1))

#define IDX_X(r, x) (r == 1 ? (ROUND1_IDX(x)) : (r == 2 ? (ROUND2_IDX(x)) : (r == 3 ? (ROUND3_IDX(x)) : ROUND4_IDX(x))))
#define IDX_A(r) (IDX_X(r, 0))
#define IDX_B(r) (IDX_X(r, 1))
#define IDX_C(r) (IDX_X(r, 2))
#define IDX_D(r) (IDX_X(r, 3))

void move_block(struct block_th *dst, const struct block_th *src)
{
    *dst = *src;
}

void xor_block(struct block_th *dst, const struct block_th *src)
{
    dst->a ^= src->a;
    dst->b ^= src->b;
    dst->c ^= src->c;
    dst->d ^= src->d;
}

__attribute__((overloadable))
void load_block(struct block_th *dst, __global const struct block_g *src, uint thread)
{
    dst->a = src->data[0 * THREADS_PER_LANE + thread];
    dst->b = src->data[1 * THREADS_PER_LANE + thread];
    dst->c = src->data[2 * THREADS_PER_LANE + thread];
    dst->d = src->data[3 * THREADS_PER_LANE + thread];
}

__attribute__((overloadable))
void load_block(struct block_th *dst, __local const struct block_g *src, uint thread)
{
    dst->a = src->data[0 * THREADS_PER_LANE + thread];
    dst->b = src->data[1 * THREADS_PER_LANE + thread];
    dst->c = src->data[2 * THREADS_PER_LANE + thread];
    dst->d = src->data[3 * THREADS_PER_LANE + thread];
}

void load_block_xor(struct block_th *dst, __global const struct block_g *src, uint thread)
{
    dst->a ^= src->data[0 * THREADS_PER_LANE + thread];
    dst->b ^= src->data[1 * THREADS_PER_LANE + thread];
    dst->c ^= src->data[2 * THREADS_PER_LANE + thread];
    dst->d ^= src->data[3 * THREADS_PER_LANE + thread];
}

__attribute__((overloadable))
void store_block(__global struct block_g *dst, const struct block_th *src, uint thread)
{
    dst->data[0 * THREADS_PER_LANE + thread] = src->a;
    dst->data[1 * THREADS_PER_LANE + thread] = src->b;
    dst->data[2 * THREADS_PER_LANE + thread] = src->c;
    dst->data[3 * THREADS_PER_LANE + thread] = src->d;
}

__attribute__((overloadable))
void store_block(__local struct block_g *dst, const struct block_th *src, uint thread)
{
    dst->data[0 * THREADS_PER_LANE + thread] = src->a;
    dst->data[1 * THREADS_PER_LANE + thread] = src->b;
    dst->data[2 * THREADS_PER_LANE + thread] = src->c;
    dst->data[3 * THREADS_PER_LANE + thread] = src->d;
}

#ifdef cl_amd_media_ops
#pragma OPENCL EXTENSION cl_amd_media_ops : enable
ulong rotr64(ulong x, ulong n)
{
    uint lo = u64_lo(x);
    uint hi = u64_hi(x);
    uint r_lo, r_hi;
    if (n < 32) {
        r_lo = amd_bitalign(hi, lo, (uint)n);
        r_hi = amd_bitalign(lo, hi, (uint)n);
    } else {
        r_lo = amd_bitalign(lo, hi, (uint)n - 32);
        r_hi = amd_bitalign(hi, lo, (uint)n - 32);
    }
    return u64_build(r_hi, r_lo);
}
#else
ulong rotr64(ulong x, ulong n)
{
    return rotate(x, 64 - n);
}
#endif

ulong f(ulong x, ulong y)
{
    uint xlo = u64_lo(x);
    uint ylo = u64_lo(y);
    return x + y + 2 * u64_build(mul_hi(xlo, ylo), xlo * ylo);
}

void g(struct block_th *block)
{
    ulong a, b, c, d;
    a = block->a;
    b = block->b;
    c = block->c;
    d = block->d;

    a = f(a, b);
    d = rotr64(d ^ a, 32);
    c = f(c, d);
    b = rotr64(b ^ c, 24);
    a = f(a, b);
    d = rotr64(d ^ a, 16);
    c = f(c, d);
    b = rotr64(b ^ c, 63);

    block->a = a;
    block->b = b;
    block->c = c;
    block->d = d;
}

void transpose1(struct block_th *block, __local struct block_g *buf, uint thread)
{
    store_block(buf, block, thread);
    barrier(CLK_LOCAL_MEM_FENCE);
    block->a = buf->data[IDX_A(1)];
    block->b = buf->data[IDX_B(1)];
    block->c = buf->data[IDX_C(1)];
    block->d = buf->data[IDX_D(1)];
}

void transpose2(struct block_th *block, __local struct block_g *buf, uint thread)
{
    buf->data[IDX_A(4)] = block->a;
    buf->data[IDX_B(4)] = block->b;
    buf->data[IDX_C(4)] = block->c;
    buf->data[IDX_D(4)] = block->d;
    barrier(CLK_LOCAL_MEM_FENCE);
    load_block(block, buf, thread);
}

void shuffle_shift1(struct block_th *block, __local struct block_g *buf, uint thread)
{
    // index of "a" doesn't change
    buf->data[IDX_B(1)] = block->b;
    buf->data[IDX_C(1)] = block->c;
    buf->data[IDX_D(1)] = block->d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block->b = buf->data[IDX_B(2)];
    block->c = buf->data[IDX_C(2)];
    block->d = buf->data[IDX_D(2)];
}

void shuffle_shift2(struct block_th *block, __local struct block_g *buf, uint thread)
{
    buf->data[IDX_A(2)] = block->a;
    buf->data[IDX_B(2)] = block->b;
    buf->data[IDX_C(2)] = block->c;
    buf->data[IDX_D(2)] = block->d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block->a = buf->data[IDX_A(3)];
    block->b = buf->data[IDX_B(3)];
    block->c = buf->data[IDX_C(3)];
    block->d = buf->data[IDX_D(3)];
}

void shuffle_shift3(struct block_th *block, __local struct block_g *buf, uint thread)
{
    // index of "a" doesn't change
    buf->data[IDX_B(3)] = block->b;
    buf->data[IDX_C(3)] = block->c;
    buf->data[IDX_D(3)] = block->d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block->b = buf->data[IDX_B(4)];
    block->c = buf->data[IDX_C(4)];
    block->d = buf->data[IDX_D(4)];
}

void shuffle_block(struct block_th *block, __local struct block_g *buf, uint thread)
{
    transpose1(block, buf, thread);
    g(block);
    shuffle_shift1(block, buf, thread);
    g(block);
    shuffle_shift2(block, buf, thread);
    g(block);
    shuffle_shift3(block, buf, thread);
    g(block);
    transpose2(block, buf, thread);
}

uint get_ref_pos(struct block_th *prev, __local struct block_g *buf, uint offset, uint thread)
{
    buf->data[thread] = prev->a;
    barrier(CLK_LOCAL_MEM_FENCE);

    ulong v = buf->data[0];
    uint ref_index = u64_lo(v);
    uint ref_area_size = offset - 1;
    ref_index = mul_hi(ref_index, ref_index);
    return ref_area_size - 1 - mul_hi(ref_area_size, ref_index);
}

void argon2_core(__global struct block_g *mem_ref,
                 __global struct block_g *mem_curr,
                 struct block_th *prev, struct block_th *tmp,
                __local struct block_g *buf, uint thread)
{
    load_block_xor(prev, mem_ref, thread);
    move_block(tmp, prev);

    shuffle_block(prev, buf, thread);

    xor_block(prev, tmp);

    store_block(mem_curr, prev, thread);
}

__kernel
#ifdef AMD
__attribute__((reqd_work_group_size(32, 2, 1)))
#else
__attribute__((reqd_work_group_size(32, 1, 1)))
#endif
void argon2(
        __local struct block_g *shuffle_bufs,
        __global struct block_g *memory)
{
    size_t job_id = get_global_id(1);
    uint warp   = get_local_id(1);
    uint thread = get_local_id(0);
    size_t nonces_per_run = get_global_size(1);

    __local struct block_g *buf = &shuffle_bufs[warp];

    /* select job's memory region: */
    memory += job_id;

    struct block_th prev, tmp;

    __global struct block_g *mem_lane = memory; // lane 0
    __global struct block_g *mem_prev = mem_lane + nonces_per_run;
    __global struct block_g *mem_curr = mem_lane + 2 * nonces_per_run;

    load_block(&prev, mem_prev, thread);

    for (uint offset = 2; offset < MEMORY_COST; offset++)
    {
        uint ref_index = get_ref_pos(&prev, buf, offset, thread);

       __global struct block_g *mem_ref = memory + ref_index * nonces_per_run;
        argon2_core(mem_ref, mem_curr, &prev, &tmp, buf, thread);

        mem_curr += nonces_per_run;
    }
}