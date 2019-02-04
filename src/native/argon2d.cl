R"===(
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

#define THREADS_PER_LANE 32
#define QWORDS_PER_THREAD (ARGON2_QWORDS_IN_BLOCK / 32)

ulong u64_build(uint hi, uint lo)
{
    return upsample(hi, lo);
}

uint u64_lo(ulong x)
{
    return (uint)x;
}

uint u64_hi(ulong x)
{
    return (uint)(x >> 32);
}

struct u64_shuffle_buf {
    uint lo[THREADS_PER_LANE];
    uint hi[THREADS_PER_LANE];
};

ulong u64_shuffle(ulong v, uint thread_src, uint thread,
                  __local struct u64_shuffle_buf *buf)
{
    uint lo = u64_lo(v);
    uint hi = u64_hi(v);

    buf->lo[thread] = lo;
    buf->hi[thread] = hi;

    barrier(CLK_LOCAL_MEM_FENCE);

    lo = buf->lo[thread_src];
    hi = buf->hi[thread_src];

    return u64_build(hi, lo);
}

struct block_g {
    ulong data[ARGON2_QWORDS_IN_BLOCK];
};

struct block_th {
    ulong a, b, c, d;
};

ulong cmpeq_mask(uint test, uint ref)
{
    uint x = -(uint)(test == ref);
    return u64_build(x, x);
}

ulong block_th_get(const struct block_th *b, uint idx)
{
    ulong res = 0;
    res ^= cmpeq_mask(idx, 0) & b->a;
    res ^= cmpeq_mask(idx, 1) & b->b;
    res ^= cmpeq_mask(idx, 2) & b->c;
    res ^= cmpeq_mask(idx, 3) & b->d;
    return res;
}

void block_th_set(struct block_th *b, uint idx, ulong v)
{
    b->a ^= cmpeq_mask(idx, 0) & (v ^ b->a);
    b->b ^= cmpeq_mask(idx, 1) & (v ^ b->b);
    b->c ^= cmpeq_mask(idx, 2) & (v ^ b->c);
    b->d ^= cmpeq_mask(idx, 3) & (v ^ b->d);
}

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

void load_block(struct block_th *dst, __global const struct block_g *src,
                uint thread)
{
    dst->a = src->data[0 * THREADS_PER_LANE + thread];
    dst->b = src->data[1 * THREADS_PER_LANE + thread];
    dst->c = src->data[2 * THREADS_PER_LANE + thread];
    dst->d = src->data[3 * THREADS_PER_LANE + thread];
}

void load_block_xor(struct block_th *dst, __global const struct block_g *src,
                    uint thread)
{
    dst->a ^= src->data[0 * THREADS_PER_LANE + thread];
    dst->b ^= src->data[1 * THREADS_PER_LANE + thread];
    dst->c ^= src->data[2 * THREADS_PER_LANE + thread];
    dst->d ^= src->data[3 * THREADS_PER_LANE + thread];
}

void store_block(__global struct block_g *dst, const struct block_th *src,
                 uint thread)
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

uint apply_shuffle_shift1(uint thread, uint idx)
{
    return (thread & 0x1c) | ((thread + idx) & 0x3);
}

uint apply_shuffle_unshift1(uint thread, uint idx)
{
    idx = (QWORDS_PER_THREAD - idx) % QWORDS_PER_THREAD;

    return apply_shuffle_shift1(thread, idx);
}

uint apply_shuffle_shift2(uint thread, uint idx)
{
    uint lo = (thread & 0x1) | ((thread & 0x10) >> 3);
    lo = (lo + idx) & 0x3;
    return ((lo & 0x2) << 3) | (thread & 0xe) | (lo & 0x1);
}

uint apply_shuffle_unshift2(uint thread, uint idx)
{
    idx = (QWORDS_PER_THREAD - idx) % QWORDS_PER_THREAD;

    return apply_shuffle_shift2(thread, idx);
}

void shuffle_shift1(struct block_th *block, uint thread,
                    __local struct u64_shuffle_buf *buf)
{
    for (uint i = 0; i < QWORDS_PER_THREAD; i++) {
        uint src_thr = apply_shuffle_shift1(thread, i);

        ulong v = block_th_get(block, i);
        v = u64_shuffle(v, src_thr, thread, buf);
        block_th_set(block, i, v);
    }
}

void shuffle_unshift1(struct block_th *block, uint thread,
                      __local struct u64_shuffle_buf *buf)
{
    for (uint i = 0; i < QWORDS_PER_THREAD; i++) {
        uint src_thr = apply_shuffle_unshift1(thread, i);

        ulong v = block_th_get(block, i);
        v = u64_shuffle(v, src_thr, thread, buf);
        block_th_set(block, i, v);
    }
}

void shuffle_shift2(struct block_th *block, uint thread,
                    __local struct u64_shuffle_buf *buf)
{
    for (uint i = 0; i < QWORDS_PER_THREAD; i++) {
        uint src_thr = apply_shuffle_shift2(thread, i);

        ulong v = block_th_get(block, i);
        v = u64_shuffle(v, src_thr, thread, buf);
        block_th_set(block, i, v);
    }
}

void shuffle_unshift2(struct block_th *block, uint thread,
                      __local struct u64_shuffle_buf *buf)
{
    for (uint i = 0; i < QWORDS_PER_THREAD; i++) {
        uint src_thr = apply_shuffle_unshift2(thread, i);

        ulong v = block_th_get(block, i);
        v = u64_shuffle(v, src_thr, thread, buf);
        block_th_set(block, i, v);
    }
}

void transpose(struct block_th *block, uint thread,
               __local struct u64_shuffle_buf *buf)
{
    uint thread_group = (thread & 0x0C) >> 2;
    for (uint i = 1; i < QWORDS_PER_THREAD; i++) {
        uint thr = (i << 2) ^ thread;
        uint idx = thread_group ^ i;

        ulong v = block_th_get(block, idx);
        v = u64_shuffle(v, thr, thread, buf);
        block_th_set(block, idx, v);
    }
}

void shuffle_block(struct block_th *block, uint thread,
                   __local struct u64_shuffle_buf *buf)
{
    transpose(block, thread, buf);

    g(block);

    shuffle_shift1(block, thread, buf);

    g(block);

    shuffle_unshift1(block, thread, buf);
    transpose(block, thread, buf);

    g(block);

    shuffle_shift2(block, thread, buf);

    g(block);

    shuffle_unshift2(block, thread, buf);
}

void compute_ref_pos(uint offset, uint *ref_index)
{
    uint ref_area_size = offset - 1;
    *ref_index = mul_hi(*ref_index, *ref_index);
    *ref_index = ref_area_size - 1 - mul_hi(ref_area_size, *ref_index);
}

void argon2_core(
        __global struct block_g *memory, __global struct block_g *mem_curr,
        struct block_th *prev, struct block_th *tmp,
        __local struct u64_shuffle_buf *shuffle_buf,
        uint thread, uint ref_index)
{
    __global struct block_g *mem_ref;
    mem_ref = memory + ref_index;

    load_block_xor(prev, mem_ref, thread);
    move_block(tmp, prev);

    shuffle_block(prev, thread, shuffle_buf);

    xor_block(prev, tmp);

    store_block(mem_curr, prev, thread);
}

void argon2_step(
        __global struct block_g *memory, __global struct block_g *mem_curr,
        struct block_th *prev, struct block_th *tmp,
        __local struct u64_shuffle_buf *shuffle_buf,
        uint thread, uint offset)
{
    ulong v = u64_shuffle(prev->a, 0, thread, shuffle_buf);
    uint ref_index = u64_lo(v);

    compute_ref_pos(offset, &ref_index);

    argon2_core(memory, mem_curr, prev, tmp, shuffle_buf, thread, ref_index);
}

__kernel
#ifdef AMD
__attribute__((reqd_work_group_size(32, 2, 1)))
#else
__attribute__((reqd_work_group_size(32, 1, 1)))
#endif
void argon2(
        __local struct u64_shuffle_buf *shuffle_bufs,
        __global struct block_g *memory, 
        uint m_cost)
{
    uint job_id = get_global_id(1);
    uint warp   = get_local_id(1); // see jobsPerBlock, warp = 0 for now
    uint thread = get_local_id(0);

    __local struct u64_shuffle_buf *shuffle_buf = &shuffle_bufs[warp];

    /* select job's memory region: */
#ifdef AMD
    memory += (size_t)job_id * (m_cost + 1);
#else
    memory += (size_t)job_id * m_cost;
#endif

    struct block_th prev, tmp;

    __global struct block_g *mem_lane = memory; // lane 0
    __global struct block_g *mem_prev = mem_lane + 1;
    __global struct block_g *mem_curr = mem_lane + 2;

    load_block(&prev, mem_prev, thread);

    for (uint offset = 2; offset < m_cost; offset++) {

        argon2_step(memory, mem_curr, &prev, &tmp, shuffle_buf, thread, offset);

        mem_curr++;
    }
}
)==="
