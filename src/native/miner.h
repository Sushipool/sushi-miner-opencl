#ifndef MINER_H_
#define MINER_H_

#include <CL/cl.h>

#define INITIAL_SEED_SIZE 256
#define ARGON2_BLOCK_SIZE 1024
#define ARGON2_MEMORY_COST 512

typedef struct
{
  char device_name[255];
  char device_vendor[255];
  char driver_version[64];
  char device_version[64];
  cl_uint max_compute_units;
  cl_uint max_clock_frequency;
  cl_ulong max_mem_alloc_size;
  cl_ulong global_mem_size;
  cl_uint nonces_per_run;
  cl_uint device_index;
  cl_device_id device_id;
  cl_context context;
  cl_command_queue queue;
  cl_program program;
  cl_mem mem_initial_seed;
  cl_mem mem_argon2_blocks;
  cl_mem mem_nonce;
  cl_kernel kernel_init_memory;
  cl_kernel kernel_argon2;
  cl_kernel kernel_find_nonce;
  size_t init_memory_global_size[2];
  size_t init_memory_local_size[2];
  size_t argon2_global_size[2];
  size_t argon2_local_size[2];
  size_t find_nonce_global_size[1];
  size_t find_nonce_local_size[1];
} worker_t;

typedef struct
{
  cl_uint num_workers;
  worker_t *workers;
} miner_t;

cl_int initialize_miner(miner_t *miner,
                        uint32_t *allowed_devices, uint32_t allowed_devices_len,
                        uint32_t *memory_sizes, uint32_t memory_sizes_len);
cl_int release_miner(miner_t *miner);
cl_int setup_worker(worker_t *worker, void *initial_seed);
cl_int mine_nonces(worker_t *worker, cl_uint start_nonce, cl_uint share_compact, cl_uint *nonce);

#endif /* MINER_H_ */
