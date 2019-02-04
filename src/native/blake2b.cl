R"===(
/*
* Blake2b
* based on reference implementation https://github.com/BLAKE2/BLAKE2
*/

#define ARGON2_HASH_LENGTH 32
#define ARGON2_BLOCK_SIZE 1024
#define ARGON2_QWORDS_IN_BLOCK (ARGON2_BLOCK_SIZE / 8)

#define BLAKE2B_HASH_LENGTH 64
#define BLAKE2B_BLOCK_SIZE 128
#define BLAKE2B_QWORDS_IN_BLOCK (BLAKE2B_BLOCK_SIZE / 8)

#define ARGON2_INITIAL_SEED_SIZE 197
#define ARGON2_PREHASH_SEED_SIZE 76

#define IV0 0x6a09e667f3bcc908UL
#define IV1 0xbb67ae8584caa73bUL
#define IV2 0x3c6ef372fe94f82bUL
#define IV3 0xa54ff53a5f1d36f1UL
#define IV4 0x510e527fade682d1UL
#define IV5 0x9b05688c2b3e6c1fUL
#define IV6 0x1f83d9abfb41bd6bUL
#define IV7 0x5be0cd19137e2179UL

struct initial_seed
{
  ulong data[32];
};

struct __attribute__ ((packed)) prehash_seed
{
  uint hashlen;
  ulong initial_hash[8];
  uint block;
  uint lane;
  uint padding[13];
};

struct argon2_block
{
  ulong data[ARGON2_QWORDS_IN_BLOCK];
};

void blake2b_init(ulong *h, uint hashlen)
{
  h[0] = IV0 ^ (0x01010000 | hashlen);
  h[1] = IV1;
  h[2] = IV2;
  h[3] = IV3;
  h[4] = IV4;
  h[5] = IV5;
  h[6] = IV6;
  h[7] = IV7;
}

#define G(a, b, c, d, x, y)          \
  do {                               \
    v[a] = v[a] + v[b] + m[x];       \
    v[d] = rotr64(v[d] ^ v[a], 32);  \
    v[c] = v[c] + v[d];              \
    v[b] = rotr64(v[b] ^ v[c], 24);  \
    v[a] = v[a] + v[b] + m[y];       \
    v[d] = rotr64(v[d] ^ v[a], 16);  \
    v[c] = v[c] + v[d];              \
    v[b] = rotr64(v[b] ^ v[c], 63);  \
  } while(0)

void blake2b_compress(ulong *h, ulong *m, uint bytes_compressed, bool last_block)
{
  ulong v[BLAKE2B_QWORDS_IN_BLOCK];

  v[0] = h[0];
  v[1] = h[1];
  v[2] = h[2];
  v[3] = h[3];
  v[4] = h[4];
  v[5] = h[5];
  v[6] = h[6];
  v[7] = h[7];
  v[8] = IV0;
  v[9] = IV1;
  v[10] = IV2;
  v[11] = IV3;
  v[12] = IV4 ^ bytes_compressed;
  v[13] = IV5; // it's OK if below 2^32 bytes
  v[14] = last_block ? ~IV6 : IV6;
  v[15] = IV7;

  // Round 0
  G(0, 4, 8, 12, 0, 1);
  G(1, 5, 9, 13, 2, 3);
  G(2, 6, 10, 14, 4, 5);
  G(3, 7, 11, 15, 6, 7);
  G(0, 5, 10, 15, 8, 9);
  G(1, 6, 11, 12, 10, 11);
  G(2, 7, 8, 13, 12, 13);
  G(3, 4, 9, 14, 14, 15);
  // Round 1
  G(0, 4, 8, 12, 14, 10);
  G(1, 5, 9, 13, 4, 8);
  G(2, 6, 10, 14, 9, 15);
  G(3, 7, 11, 15, 13, 6);
  G(0, 5, 10, 15, 1, 12);
  G(1, 6, 11, 12, 0, 2);
  G(2, 7, 8, 13, 11, 7);
  G(3, 4, 9, 14, 5, 3);
  // Round 2
  G(0, 4, 8, 12, 11, 8);
  G(1, 5, 9, 13, 12, 0);
  G(2, 6, 10, 14, 5, 2);
  G(3, 7, 11, 15, 15, 13);
  G(0, 5, 10, 15, 10, 14);
  G(1, 6, 11, 12, 3, 6);
  G(2, 7, 8, 13, 7, 1);
  G(3, 4, 9, 14, 9, 4); 
  // Round 3
  G(0, 4, 8, 12, 7, 9);
  G(1, 5, 9, 13, 3, 1);
  G(2, 6, 10, 14, 13, 12);
  G(3, 7, 11, 15, 11, 14);
  G(0, 5, 10, 15, 2, 6);
  G(1, 6, 11, 12, 5, 10);
  G(2, 7, 8, 13, 4, 0);
  G(3, 4, 9, 14, 15, 8);
  // Round 4
  G(0, 4, 8, 12, 9, 0);
  G(1, 5, 9, 13, 5, 7);
  G(2, 6, 10, 14, 2, 4);
  G(3, 7, 11, 15, 10, 15);
  G(0, 5, 10, 15, 14, 1);
  G(1, 6, 11, 12, 11, 12);
  G(2, 7, 8, 13, 6, 8);
  G(3, 4, 9, 14, 3, 13); 
  // Round 5
  G(0, 4, 8, 12, 2, 12);
  G(1, 5, 9, 13, 6, 10);
  G(2, 6, 10, 14, 0, 11);
  G(3, 7, 11, 15, 8, 3);
  G(0, 5, 10, 15, 4, 13);
  G(1, 6, 11, 12, 7, 5);
  G(2, 7, 8, 13, 15, 14);
  G(3, 4, 9, 14, 1, 9);
  // Round 6
  G(0, 4, 8, 12, 12, 5);
  G(1, 5, 9, 13, 1, 15);
  G(2, 6, 10, 14, 14, 13);
  G(3, 7, 11, 15, 4, 10);
  G(0, 5, 10, 15, 0, 7);
  G(1, 6, 11, 12, 6, 3);
  G(2, 7, 8, 13, 9, 2);
  G(3, 4, 9, 14, 8, 11);
  // Round 7
  G(0, 4, 8, 12, 13, 11);
  G(1, 5, 9, 13, 7, 14);
  G(2, 6, 10, 14, 12, 1);
  G(3, 7, 11, 15, 3, 9);
  G(0, 5, 10, 15, 5, 0);
  G(1, 6, 11, 12, 15, 4);
  G(2, 7, 8, 13, 8, 6);
  G(3, 4, 9, 14, 2, 10);
  // Round 8
  G(0, 4, 8, 12, 6, 15);
  G(1, 5, 9, 13, 14, 9);
  G(2, 6, 10, 14, 11, 3);
  G(3, 7, 11, 15, 0, 8);
  G(0, 5, 10, 15, 12, 2);
  G(1, 6, 11, 12, 13, 7);
  G(2, 7, 8, 13, 1, 4);
  G(3, 4, 9, 14, 10, 5);
  // Round 9
  G(0, 4, 8, 12, 10, 2);
  G(1, 5, 9, 13, 8, 4);
  G(2, 6, 10, 14, 7, 6);
  G(3, 7, 11, 15, 1, 5);
  G(0, 5, 10, 15, 15, 11);
  G(1, 6, 11, 12, 9, 14);
  G(2, 7, 8, 13, 3, 12);
  G(3, 4, 9, 14, 13, 0);
  // Round 10
  G(0, 4, 8, 12, 0, 1);
  G(1, 5, 9, 13, 2, 3);
  G(2, 6, 10, 14, 4, 5);
  G(3, 7, 11, 15, 6, 7);
  G(0, 5, 10, 15, 8, 9);
  G(1, 6, 11, 12, 10, 11);
  G(2, 7, 8, 13, 12, 13);
  G(3, 4, 9, 14, 14, 15);
  // Round 11
  G(0, 4, 8, 12, 14, 10);
  G(1, 5, 9, 13, 4, 8);
  G(2, 6, 10, 14, 9, 15);
  G(3, 7, 11, 15, 13, 6);
  G(0, 5, 10, 15, 1, 12);
  G(1, 6, 11, 12, 0, 2);
  G(2, 7, 8, 13, 11, 7);
  G(3, 4, 9, 14, 5, 3);

  h[0] = h[0] ^ v[0] ^ v[8];
  h[1] = h[1] ^ v[1] ^ v[9];
  h[2] = h[2] ^ v[2] ^ v[10];
  h[3] = h[3] ^ v[3] ^ v[11];
  h[4] = h[4] ^ v[4] ^ v[12];
  h[5] = h[5] ^ v[5] ^ v[13];
  h[6] = h[6] ^ v[6] ^ v[14];
  h[7] = h[7] ^ v[7] ^ v[15];
}

void set_nonce(struct initial_seed *seed, uint nonce)
{
  // bytes 170-173
  ulong n = ((nonce & 0xFF000000) >> 24)
    | ((nonce & 0x00FF0000) >> 8)
    | ((nonce & 0x0000FF00) << 8)
    | ((nonce & 0x000000FF) << 24);
  seed->data[21] = (seed->data[21] & 0xFFFF00000000FFFFUL) | (n << 16);
}

void initial_hash(global struct initial_seed *inseed, uint m_cost, uint nonce, ulong *hash)
{
  struct initial_seed is = *inseed;
  set_nonce(&is, nonce);

  blake2b_init(hash, BLAKE2B_HASH_LENGTH);
  blake2b_compress(hash, &is.data[0], BLAKE2B_BLOCK_SIZE, false);
  blake2b_compress(hash, &is.data[BLAKE2B_QWORDS_IN_BLOCK], ARGON2_INITIAL_SEED_SIZE, true);
}

void fill_block(struct prehash_seed *phseed, global struct argon2_block *memory)
{
  ulong h[8];
  ulong buffer[BLAKE2B_QWORDS_IN_BLOCK] = {0};
  global ulong *dst = memory->data;

  // V1
  blake2b_init(h, BLAKE2B_HASH_LENGTH);
  blake2b_compress(h, (ulong*) phseed, ARGON2_PREHASH_SEED_SIZE, true);

  *(dst++) = h[0];
  *(dst++) = h[1];
  *(dst++) = h[2];
  *(dst++) = h[3];

  // V2-Vr
  for (uint r = 2; r < 2 * ARGON2_BLOCK_SIZE / BLAKE2B_HASH_LENGTH; r++)
  {
    buffer[0] = h[0];
    buffer[1] = h[1];
    buffer[2] = h[2];
    buffer[3] = h[3];
    buffer[4] = h[4];
    buffer[5] = h[5];
    buffer[6] = h[6];
    buffer[7] = h[7];

    blake2b_init(h, BLAKE2B_HASH_LENGTH);
    blake2b_compress(h, buffer, BLAKE2B_HASH_LENGTH, true);

    *(dst++) = h[0];
    *(dst++) = h[1];
    *(dst++) = h[2];
    *(dst++) = h[3];
  }

  *(dst++) = h[4];
  *(dst++) = h[5];
  *(dst++) = h[6];
  *(dst++) = h[7];
}

#ifdef AMD
void fill_first_blocks(global struct initial_seed *inseed, global struct argon2_block *memory, uint m_cost, uint nonce, uint block)
#else
void fill_first_blocks(global struct initial_seed *inseed, global struct argon2_block *memory, uint m_cost, uint nonce)
#endif
{
  struct prehash_seed phs = {
    ARGON2_BLOCK_SIZE
  };

  initial_hash(inseed, m_cost, nonce, phs.initial_hash);

#ifdef AMD
  phs.block = block;
  fill_block(&phs, memory);
#else
  phs.block = 0;
  fill_block(&phs, memory);

  phs.block = 1;
  fill_block(&phs, memory + 1);
#endif
}

void nbits_to_target(uint nbits, uchar *target)
{
  uint offset = (31 - (nbits >> 24)); // offset in bytes
  uint value = nbits & 0xFFFFFF;

  #pragma unroll
  for (uint i = 0; i < ARGON2_HASH_LENGTH; i++)
  {
    target[i] = 0;
  }
  target[++offset] = (uchar) (value >> 16);
  target[++offset] = (uchar) (value >> 8);
  target[++offset] = (uchar) (value);
}

bool is_proof_of_work(uchar *hash, uchar *target)
{
  #pragma unroll
  for (uint i = 0; i < ARGON2_HASH_LENGTH; i++)
  {
    if (hash[i] < target[i]) return true;
    if (hash[i] > target[i]) return false;
  }
  return true;
}

void hash_last_block(global struct argon2_block *memory, ulong *hash)
{
  ulong h[8];
  ulong buffer[BLAKE2B_QWORDS_IN_BLOCK];
  uint i, hi, lo;
  uint bytes_compressed = 0;
  uint bytes_remaining = ARGON2_BLOCK_SIZE;
  global uint *src = (global uint*) memory->data;

  blake2b_init(h, ARGON2_HASH_LENGTH);

  hi = *(src++);
  buffer[0] = ARGON2_HASH_LENGTH | ((ulong) hi << 32);

  #pragma unroll
  for (i = 1; i < BLAKE2B_QWORDS_IN_BLOCK; i++)
  {
    lo = *(src++);
    hi = *(src++);
    buffer[i] = lo | ((ulong) hi << 32);
  }

  bytes_compressed += BLAKE2B_BLOCK_SIZE;
  bytes_remaining -= (BLAKE2B_BLOCK_SIZE - sizeof(uint));
  blake2b_compress(h, buffer, bytes_compressed, false);

  while (bytes_remaining > BLAKE2B_BLOCK_SIZE)
  {
    #pragma unroll
    for (i = 0; i < BLAKE2B_QWORDS_IN_BLOCK; i++)
    {
      lo = *(src++);
      hi = *(src++);
      buffer[i] = lo | ((ulong) hi << 32);
    }
    bytes_compressed += BLAKE2B_BLOCK_SIZE;
    bytes_remaining -= BLAKE2B_BLOCK_SIZE;
    blake2b_compress(h, buffer, bytes_compressed, false);
  }

  buffer[0] = *src;
  #pragma unroll
  for (i = 1; i < BLAKE2B_QWORDS_IN_BLOCK; i++)
  {
    buffer[i] = 0;
  }
  bytes_compressed += bytes_remaining;
  blake2b_compress(h, buffer, bytes_compressed, true);

  hash[0] = h[0];
  hash[1] = h[1];
  hash[2] = h[2];
  hash[3] = h[3];
}


__kernel
#ifdef AMD
__attribute__((reqd_work_group_size(32, 2, 1)))
#else
__attribute__((reqd_work_group_size(32, 1, 1)))
#endif
void init_memory(global struct initial_seed *inseed, global struct argon2_block *memory, uint m_cost)
{
  uint nonce = get_global_id(0);
  uint start_nonce = get_global_offset(0);

#ifdef AMD
  uint block = get_local_id(1);
  memory += (size_t) (nonce - start_nonce) * (m_cost + 1) + block;
  fill_first_blocks(inseed, memory, m_cost, nonce, block);
#else
  memory += (size_t) (nonce - start_nonce) * m_cost;
  fill_first_blocks(inseed, memory, m_cost, nonce);
#endif
}

__kernel
__attribute__((reqd_work_group_size(32, 1, 1)))
void find_nonce(uint nbits, global struct argon2_block *memory, uint m_cost, global uint *nonce_found)
{
  uint nonce = get_global_id(0);
  uint start_nonce = get_global_offset(0);

  uchar hash[ARGON2_HASH_LENGTH];
  uchar target[ARGON2_HASH_LENGTH];

#ifdef AMD
  memory += (size_t) (nonce - start_nonce + 1) * (m_cost + 1) - 2;
#else
  memory += (size_t) (nonce - start_nonce + 1) * m_cost - 1;
#endif

  nbits_to_target(nbits, target);
  hash_last_block(memory, (ulong*) hash);

  if (is_proof_of_work(hash, target))
  {
    atomic_cmpxchg(nonce_found, 0, nonce);
  }
}
)==="
