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

void load_block(struct block_th *dst, __global const struct block_g *src, uint thread)
{
    dst->a = src->data[0 * THREADS_PER_LANE + thread];
    dst->b = src->data[1 * THREADS_PER_LANE + thread];
    dst->c = src->data[2 * THREADS_PER_LANE + thread];
    dst->d = src->data[3 * THREADS_PER_LANE + thread];
}

__attribute__((overloadable))
void load_block_xor(struct block_th *dst, __global const struct block_g *src, uint thread)
{
    dst->a ^= src->data[0 * THREADS_PER_LANE + thread];
    dst->b ^= src->data[1 * THREADS_PER_LANE + thread];
    dst->c ^= src->data[2 * THREADS_PER_LANE + thread];
    dst->d ^= src->data[3 * THREADS_PER_LANE + thread];
}

__attribute__((overloadable))
void load_block_xor(struct block_th *dst, __local const struct block_g *src, uint thread)
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

uint get_ref_pos(struct block_th *prev, __local struct block_g *buf, uint curr_index, uint thread)
{
    if (thread == 0)
    {
        buf->data[thread] = prev->a;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    ulong v = buf->data[0];
    uint ref_index = u64_lo(v);
    uint ref_area_size = curr_index - 1;
    ref_index = mul_hi(ref_index, ref_index);
    return ref_area_size - 1 - mul_hi(ref_area_size, ref_index);
}

void argon2_core(__global struct block_g *memory,
                 uint curr_index, uint ref_index, uint nonces_per_run,
                 struct block_th *prev, __local struct block_g *buf, uint thread
#ifdef LDS_CACHE_SIZE
                 , __local struct block_g *cache
#endif
                 )
{
    struct block_th block;

    // Load from memory + XOR
#ifdef LDS_CACHE_SIZE
    if (ref_index < LDS_CACHE_SIZE)
    {
        load_block_xor(prev, &cache[ref_index], thread);
    }
    else {
#endif
        __global struct block_g * mem_ref = memory + ref_index * nonces_per_run;
        load_block_xor(prev, mem_ref, thread);
#ifdef LDS_CACHE_SIZE
    }
#endif

    // Transpose 1
    store_block(buf, prev, thread);
    barrier(CLK_LOCAL_MEM_FENCE);
    block.a = buf->data[IDX_A(1)];
    block.b = buf->data[IDX_B(1)];
    block.c = buf->data[IDX_C(1)];
    block.d = buf->data[IDX_D(1)];

    g(&block);

    // Shuffle 1, index of A doesn't change
    buf->data[IDX_B(1)] = block.b;
    buf->data[IDX_C(1)] = block.c;
    buf->data[IDX_D(1)] = block.d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block.b = buf->data[IDX_B(2)];
    block.c = buf->data[IDX_C(2)];
    block.d = buf->data[IDX_D(2)];

    g(&block);

    // Shuffle 2
    buf->data[IDX_A(2)] = block.a;
    buf->data[IDX_B(2)] = block.b;
    buf->data[IDX_C(2)] = block.c;
    buf->data[IDX_D(2)] = block.d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block.a = buf->data[IDX_A(3)];
    block.b = buf->data[IDX_B(3)];
    block.c = buf->data[IDX_C(3)];
    block.d = buf->data[IDX_D(3)];

    g(&block);

    // Shuffle 3, index of A doesn't change
    buf->data[IDX_B(3)] = block.b;
    buf->data[IDX_C(3)] = block.c;
    buf->data[IDX_D(3)] = block.d;
    barrier(CLK_LOCAL_MEM_FENCE);
    block.b = buf->data[IDX_B(4)];
    block.c = buf->data[IDX_C(4)];
    block.d = buf->data[IDX_D(4)];

    g(&block);

    // Transpose 2 + XOR
    buf->data[IDX_A(4)] = block.a;
    buf->data[IDX_B(4)] = block.b;
    buf->data[IDX_C(4)] = block.c;
    buf->data[IDX_D(4)] = block.d;
    barrier(CLK_LOCAL_MEM_FENCE);
    load_block_xor(prev, buf, thread);

    // Store to memory
#ifdef LDS_CACHE_SIZE
    if (curr_index < LDS_CACHE_SIZE)
    {
        store_block(&cache[curr_index], prev, thread);
    }
    else {
#endif
        __global struct block_g *mem_curr = memory + curr_index * nonces_per_run;
        store_block(mem_curr, prev, thread);
#ifdef LDS_CACHE_SIZE
    }
#endif
}

__kernel
#ifdef AMD
__attribute__((reqd_work_group_size(32, 2, 1)))
#else
__attribute__((reqd_work_group_size(32, 1, 1)))
#endif
void argon2(__local struct block_g *lds, __global struct block_g *memory)
{
    uint job_id = get_global_id(1);
    uint warp   = get_local_id(1);
    uint jobs_per_block  = get_local_size(1);
    uint thread = get_local_id(0);
    uint nonces_per_run = get_global_size(1);

    __local struct block_g *buf = &lds[warp];
#ifdef LDS_CACHE_SIZE
    __local struct block_g *cache = &lds[jobs_per_block + LDS_CACHE_SIZE * warp];
#endif

    /* select job's memory region: */
    memory += job_id;

    struct block_th first, prev;
    load_block(&prev, memory + nonces_per_run, thread);

#ifdef LDS_CACHE_SIZE
    load_block(&first, memory, thread);
    store_block(&cache[0], &first, thread);
    store_block(&cache[1], &prev, thread);
#endif

    for (uint curr_index = 2; curr_index < MEMORY_COST; curr_index++)
    {
        uint ref_index = get_ref_pos(&prev, buf, curr_index, thread);
        argon2_core(memory, curr_index, ref_index, nonces_per_run, &prev, buf, thread
#ifdef LDS_CACHE_SIZE
            , cache
#endif
        );
    }
}