#include "kernels.h"

__host__ void set_block_header(struct worker_t *worker, uint32_t threadIndex, nimiq_block_header *block_header)
{
    initial_seed inseed;
    inseed.lanes = 1;
    inseed.hash_len = ARGON2_HASH_LENGTH;
    inseed.memory_cost = NIMIQ_ARGON2_COST;
    inseed.iterations = 1;
    inseed.version = 0x13;
    inseed.type = 0;
    inseed.header_len = sizeof(nimiq_block_header);
    memcpy(&inseed.header, block_header, sizeof(nimiq_block_header));
    inseed.salt_len = NIMIQ_ARGON2_SALT_LEN;
    memcpy(&inseed.salt, NIMIQ_ARGON2_SALT, NIMIQ_ARGON2_SALT_LEN);
    inseed.secret_len = 0;
    inseed.extra_len = 0;
    memset(&inseed.padding, 0, sizeof(inseed.padding));
  
    cudaMemcpyAsync(worker->inseed[threadIndex], &inseed, sizeof(initial_seed), cudaMemcpyHostToDevice);
    cudaMemsetAsync(worker->nonce[threadIndex], 0, sizeof(uint32_t)); // zero nonce
}

__host__ uint32_t mine_nonces(struct worker_t *worker, uint32_t threadIndex, uint32_t start_nonce, uint32_t share_compact)
{
    init_memory<<<worker->init_memory_blocks, worker->init_memory_threads>>>(worker->memory[threadIndex], worker->inseed[threadIndex], start_nonce);
    argon2<<<worker->argon2_blocks, worker->argon2_threads, worker->cacheSize * ARGON2_BLOCK_SIZE>>>(worker->memory[threadIndex], worker->cacheSize, worker->memoryTradeoff);
    get_nonce<<<worker->get_nonce_blocks, worker->get_nonce_threads>>>(worker->memory[threadIndex], start_nonce, share_compact, worker->nonce[threadIndex]);

    cudaStreamSynchronize(0);

    uint32_t nonce;
    cudaMemcpy(&nonce, worker->nonce[threadIndex], sizeof(uint32_t), cudaMemcpyDeviceToHost);

    if (nonce > 0)
    {
        cudaMemsetAsync(worker->nonce[threadIndex], 0, sizeof(uint32_t)); // zero nonce
    }
    return nonce;
}
