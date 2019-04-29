/*
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
* Simplified version of https://gitlab.com/omos/argon2-gpu
*/

#include "kernels.h"

__device__ uint64_t u64_build(uint32_t hi, uint32_t lo)
{
    return ((uint64_t)hi << 32) | (uint64_t)lo;
}

__device__ uint32_t u64_lo(uint64_t x)
{
    return (uint32_t)x;
}

__device__ uint32_t u64_hi(uint64_t x)
{
    return (uint32_t)(x >> 32);
}

__device__ uint64_t u64_shuffle(uint64_t v, uint32_t thread)
{
    uint32_t lo = u64_lo(v);
    uint32_t hi = u64_hi(v);
    lo = __shfl_sync(0xFFFFFFFF, lo, thread);
    hi = __shfl_sync(0xFFFFFFFF, hi, thread);
    return u64_build(hi, lo);
}

struct block_th
{
    uint64_t a, b, c, d;
};

__device__ uint64_t cmpeq_mask(uint32_t test, uint32_t ref)
{
    uint32_t x = -(uint32_t)(test == ref);
    return u64_build(x, x);
}

__device__ uint64_t block_th_get(const struct block_th *b, uint32_t idx)
{
    uint64_t res = 0;
    res ^= cmpeq_mask(idx, 0) & b->a;
    res ^= cmpeq_mask(idx, 1) & b->b;
    res ^= cmpeq_mask(idx, 2) & b->c;
    res ^= cmpeq_mask(idx, 3) & b->d;
    return res;
}

__device__ void block_th_set(struct block_th *b, uint32_t idx, uint64_t v)
{
    b->a ^= cmpeq_mask(idx, 0) & (v ^ b->a);
    b->b ^= cmpeq_mask(idx, 1) & (v ^ b->b);
    b->c ^= cmpeq_mask(idx, 2) & (v ^ b->c);
    b->d ^= cmpeq_mask(idx, 3) & (v ^ b->d);
}

__device__ void move_block(struct block_th *dst, const struct block_th *src)
{
    *dst = *src;
}

__device__ void xor_block(struct block_th *dst, const struct block_th *src)
{
    dst->a ^= src->a;
    dst->b ^= src->b;
    dst->c ^= src->c;
    dst->d ^= src->d;
}

__device__ void load_block(struct block_th *dst, const struct block_g *src, uint32_t thread)
{
    dst->a = src->data[0 * THREADS_PER_LANE + thread];
    dst->b = src->data[1 * THREADS_PER_LANE + thread];
    dst->c = src->data[2 * THREADS_PER_LANE + thread];
    dst->d = src->data[3 * THREADS_PER_LANE + thread];
}

__device__ void load_block_xor(struct block_th *dst, const struct block_g *src, uint32_t thread)
{
    dst->a ^= src->data[0 * THREADS_PER_LANE + thread];
    dst->b ^= src->data[1 * THREADS_PER_LANE + thread];
    dst->c ^= src->data[2 * THREADS_PER_LANE + thread];
    dst->d ^= src->data[3 * THREADS_PER_LANE + thread];
}

__device__ void store_block(struct block_g *dst, const struct block_th *src, uint32_t thread)
{
    dst->data[0 * THREADS_PER_LANE + thread] = src->a;
    dst->data[1 * THREADS_PER_LANE + thread] = src->b;
    dst->data[2 * THREADS_PER_LANE + thread] = src->c;
    dst->data[3 * THREADS_PER_LANE + thread] = src->d;
}

__device__ uint64_t rotr64(uint64_t x, uint32_t n)
{
    return (x >> n) | (x << (64 - n));
}

__device__ uint64_t f(uint64_t x, uint64_t y)
{
    uint32_t xlo = u64_lo(x);
    uint32_t ylo = u64_lo(y);
    return x + y + 2 * u64_build(__umulhi(xlo, ylo), xlo * ylo);
}

__device__ void g(struct block_th *block)
{
    uint64_t a, b, c, d;
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

template<class shuffle>
__device__ void apply_shuffle(struct block_th *block, uint32_t thread)
{
    for (uint32_t i = 0; i < QWORDS_PER_THREAD; i++) {
        uint32_t src_thr = shuffle::apply(thread, i);

        uint64_t v = block_th_get(block, i);
        v = u64_shuffle(v, src_thr);
        block_th_set(block, i, v);
    }
}

__device__ void transpose(struct block_th *block, uint32_t thread)
{
    uint32_t thread_group = (thread & 0x0C) >> 2;
    for (uint32_t i = 1; i < QWORDS_PER_THREAD; i++) {
        uint32_t thr = (i << 2) ^ thread;
        uint32_t idx = thread_group ^ i;

        uint64_t v = block_th_get(block, idx);
        v = u64_shuffle(v, thr);
        block_th_set(block, idx, v);
    }
}

struct shift1_shuffle {
    __device__ static uint32_t apply(uint32_t thread, uint32_t idx)
    {
        return (thread & 0x1c) | ((thread + idx) & 0x3);
    }
};

struct unshift1_shuffle {
    __device__ static uint32_t apply(uint32_t thread, uint32_t idx)
    {
        idx = (QWORDS_PER_THREAD - idx) % QWORDS_PER_THREAD;

        return (thread & 0x1c) | ((thread + idx) & 0x3);
    }
};

struct shift2_shuffle {
    __device__ static uint32_t apply(uint32_t thread, uint32_t idx)
    {
        uint32_t lo = (thread & 0x1) | ((thread & 0x10) >> 3);
        lo = (lo + idx) & 0x3;
        return ((lo & 0x2) << 3) | (thread & 0xe) | (lo & 0x1);
    }
};

struct unshift2_shuffle {
    __device__ static uint32_t apply(uint32_t thread, uint32_t idx)
    {
        idx = (QWORDS_PER_THREAD - idx) % QWORDS_PER_THREAD;

        uint32_t lo = (thread & 0x1) | ((thread & 0x10) >> 3);
        lo = (lo + idx) & 0x3;
        return ((lo & 0x2) << 3) | (thread & 0xe) | (lo & 0x1);
    }
};

__device__ void shuffle_block(struct block_th *block, uint32_t thread)
{
    transpose(block, thread);

    g(block);

    apply_shuffle<shift1_shuffle>(block, thread);

    g(block);

    apply_shuffle<unshift1_shuffle>(block, thread);
    transpose(block, thread);

    g(block);

    apply_shuffle<shift2_shuffle>(block, thread);

    g(block);

    apply_shuffle<unshift2_shuffle>(block, thread);
}

__device__ uint32_t compute_ref_index(struct block_th *prev, uint32_t curr_index)
{
    uint64_t v = u64_shuffle(prev->a, 0);
    uint32_t ref_index = u64_lo(v);

    uint32_t ref_area_size = curr_index - 1;
    ref_index = __umulhi(ref_index, ref_index);
    ref_index = ref_area_size - 1 - __umulhi(ref_area_size, ref_index);
    return ref_index;
}

__device__ void load_block(struct block_th *dst,
                           const struct block_g *memory,
                           const struct block_g *cache, uint32_t cacheSize,
                           uint32_t index, uint32_t thread)
{
    if (index < 2 + cacheSize && index >= 2)
    {
        load_block(dst, cache + index - 2, thread);
    }
    else
    {
        load_block(dst, memory + index, thread);
    }
}

__device__ void load_block_xor(struct block_th *dst,
                               const struct block_g *memory,
                               const struct block_g *cache, uint32_t cacheSize,
                               uint32_t index, uint32_t thread)
{
    if (index < 2 + cacheSize && index >= 2)
    {
        load_block_xor(dst, cache + index - 2, thread);
    }
    else
    {
        load_block_xor(dst, memory + index, thread);
    }
}

__device__ void store_block(struct block_g *memory,
                            struct block_g *cache, uint32_t cacheSize,
                            const struct block_th *src,
                            uint32_t index, uint32_t thread)
{
    if (index < 2 + cacheSize && index >= 2)
    {
        store_block(cache + index - 2, src, thread);
    }
    else
    {
        store_block(memory + index, src, thread);
    }
}

__device__ void get_ref_index(uint32_t *ref_index, bool *is_stored, const uint16_t *ref_indexes, uint32_t index)
{
    uint16_t ri = ref_indexes[index];
    *ref_index = (ri & 0x7FFF);
    *is_stored = (bool) (ri & 0x8000);
}

__device__ void set_ref_index(uint16_t *ref_indexes, uint32_t index, uint32_t ref_index, bool is_stored, uint32_t thread)
{
    if (thread == 0)
    {
        ref_indexes[index] = (is_stored ? 0x8000 : 0) | ref_index;
    }
    __syncwarp();
}

__device__ void compute_block_xor(struct block_th *dst,
                                const struct block_g *memory,
                                const struct block_g *cache, uint32_t cacheSize,
                                uint32_t index, uint32_t ref_index, uint32_t thread)
{
    struct block_th prev, tmp;

    load_block(&prev, memory, cache, cacheSize, index - 1, thread);
    load_block_xor(&prev, memory, cache, cacheSize, ref_index, thread);

    move_block(&tmp, &prev);
    shuffle_block(&prev, thread);
    xor_block(&prev, &tmp);

    xor_block(dst, &prev);
}

__device__ void argon2_step(struct block_g *memory, struct block_g *cache, uint32_t cacheSize,
                            uint16_t *ref_indexes, uint32_t memoryTradeoff,
                            uint32_t curr_index, struct block_th *prev, bool *is_prev_stored, uint32_t thread)
{
    struct block_th tmp;
    bool is_ref_stored = true;
    bool is_curr_stored = true;

    uint32_t ref_index = compute_ref_index(prev, curr_index);

    if (curr_index >= memoryTradeoff)
    {
        if (ref_index >= memoryTradeoff && ref_index >= 2)
        {
            // what was the ref block of the current ref block?
            uint32_t ref_ref_index;
            get_ref_index(&ref_ref_index, &is_ref_stored, ref_indexes, ref_index);
            if (!is_ref_stored)
            {
                compute_block_xor(prev, memory, cache, cacheSize, ref_index, ref_ref_index, thread);
            }
        }
        is_curr_stored = !(*is_prev_stored && is_ref_stored) || (curr_index == MEMORY_COST - 1);

        set_ref_index(ref_indexes, curr_index, ref_index, is_curr_stored, thread);
    }

    // load if it was not computed before 
    if (is_ref_stored)
    {
        load_block_xor(prev, memory, cache, cacheSize, ref_index, thread);
    }

    move_block(&tmp, prev);
    shuffle_block(prev, thread);
    xor_block(prev, &tmp);

    if (is_curr_stored)
    {
        store_block(memory, cache, cacheSize, prev, curr_index, thread);
    }
    *is_prev_stored = is_curr_stored;
}

__global__ void argon2(struct block_g *memory, uint32_t cacheSize, uint32_t memoryTradeoff)
{
    extern __shared__ struct block_g cache[];
    // ref_index of the current block, msb = 1 if current block is stored to global mem
    __shared__ uint16_t ref_indexes[MEMORY_COST];

    uint32_t job_id = blockIdx.y;
    uint32_t thread = threadIdx.x;

    /* select job's memory region: */
    memory += (size_t)job_id * MEMORY_COST;

    struct block_th prev;
    bool is_prev_stored = true;

    load_block(&prev, memory + 1, thread);

    for (uint32_t curr_index = 2; curr_index < MEMORY_COST; curr_index++)
    {
        argon2_step(memory, cache, cacheSize, ref_indexes, memoryTradeoff, curr_index, &prev, &is_prev_stored, thread);
    }
}
