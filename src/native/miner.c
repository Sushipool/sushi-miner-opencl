#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "miner.h"

const char *ARGON2D_CL =
#include "./argon2d.cl"
;

const char *BLAKE2B_CL =
#include "./blake2b.cl"
;

#define VENDOR_AMD "Advanced Micro Devices"
#define VENDOR_NVIDIA "NVIDIA Corporation"

#define ONE_GB 0x40000000L
#define ONE_MB 0x100000L
#define NONCES_PER_GROUP 32
#define THREADS_PER_LANE 32

#define CL_CHECK(_expr)                                                        \
  do                                                                           \
  {                                                                            \
    cl_int _err = _expr;                                                       \
    if (_err != CL_SUCCESS)                                                    \
    {                                                                          \
      fprintf(stderr, "OpenCL Error: '%s' returned %d.\n", #_expr, (int)_err); \
      return _err;                                                             \
    }                                                                          \
  } while (0)

#ifdef _WIN32
#define CL_CHECK_ERR(_expr) _expr
#else
#define CL_CHECK_ERR(_expr)                                                    \
  ({                                                                           \
    cl_int _err = CL_INVALID_VALUE;                                            \
    __typeof__(_expr) _ret = _expr;                                            \
    if (_err != CL_SUCCESS)                                                    \
    {                                                                          \
      fprintf(stderr, "OpenCL Error: '%s' returned %d.\n", #_expr, (int)_err); \
      return _err;                                                             \
    }                                                                          \
    _ret;                                                                      \
  })
#endif

const cl_uint zero = 0;

cl_int initialize_miner(miner_t *miner,
                        uint32_t *allowed_devices, uint32_t allowed_devices_len,
                        uint32_t *memory_sizes, uint32_t memory_sizes_len)
{
#ifdef _WIN32
  cl_int _err;
#endif
  miner->num_workers = 0;
  miner->workers = NULL;

  cl_uint global_device_idx = 0;
  cl_uint worker_idx = 0;

  // Find all OpenCL platforms
  cl_uint num_platforms;
  cl_platform_id *platforms = NULL;
  CL_CHECK(clGetPlatformIDs(0, NULL, &num_platforms));
  if (num_platforms < 1)
  {
    fprintf(stderr, "Failed to find OpenCL platforms.\n");
    return CL_INVALID_PLATFORM;
  }

  const char *sources[2];
  sources[0] = ARGON2D_CL;
  sources[1] = BLAKE2B_CL;

  size_t source_lengths[2];
  source_lengths[0] = strlen(ARGON2D_CL);
  source_lengths[1] = strlen(BLAKE2B_CL);

  platforms = (cl_platform_id *)malloc(sizeof(cl_platform_id) * num_platforms);

  CL_CHECK(clGetPlatformIDs(num_platforms, platforms, NULL));

  for (cl_uint platform_idx = 0; platform_idx < num_platforms; platform_idx++)
  {
    cl_platform_id platform = platforms[platform_idx];

    char platform_name[64];
    char platform_vendor[64];
    CL_CHECK(clGetPlatformInfo(platform, CL_PLATFORM_NAME, sizeof(platform_name), platform_name, NULL));
    CL_CHECK(clGetPlatformInfo(platform, CL_PLATFORM_VENDOR, sizeof(platform_vendor), platform_vendor, NULL));

    printf("Platform: %s by %s\n", platform_name, platform_vendor);

    cl_bool is_amd = (strncmp(platform_vendor, VENDOR_AMD, strlen(VENDOR_AMD)) == 0);
    cl_bool is_nvidia = (strncmp(platform_vendor, VENDOR_NVIDIA, strlen(VENDOR_NVIDIA)) == 0);

    if (!is_amd && !is_nvidia)
    {
      printf("  Unsupported platform, skipped.\n");
      continue;
    }
    char *build_options = (is_amd ? "-Werror -DAMD" : "-Werror");

    // Find all GPU devices
    cl_uint num_devices;
    cl_device_id *devices = NULL;
    CL_CHECK(clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 0, NULL, &num_devices));
    if (num_devices < 1)
    {
      printf("  No GPU devices found.\n");
      continue;
    }

    devices = (cl_device_id *)malloc(sizeof(cl_device_id) * num_devices);
    CL_CHECK(clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, num_devices, devices, NULL));

    // Iterate over devices, setup workers
    for (cl_uint device_idx = 0; device_idx < num_devices; device_idx++, global_device_idx++)
    {
      // Check if this device is allowed
      cl_bool allowed = (allowed_devices_len == 0) || (worker_idx < allowed_devices_len && allowed_devices[worker_idx] == global_device_idx);
      if (!allowed)
      {
        printf("  Device #%u:\n    Disabled by user\n", global_device_idx);
        continue;
      }

      miner->num_workers++;
      miner->workers = (worker_t *)realloc(miner->workers, sizeof(worker_t) * miner->num_workers);
      worker_t *worker = &miner->workers[worker_idx];
      worker->device_index = global_device_idx;
      worker->device_id = devices[device_idx];

      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_NAME, sizeof(worker->device_name), &worker->device_name, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_VENDOR, sizeof(worker->device_vendor), &worker->device_vendor, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DRIVER_VERSION, sizeof(worker->driver_version), &worker->driver_version, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_VERSION, sizeof(worker->device_version), &worker->device_version, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(worker->max_compute_units), &worker->max_compute_units, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof(worker->max_clock_frequency), &worker->max_clock_frequency, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(worker->max_mem_alloc_size), &worker->max_mem_alloc_size, NULL));
      CL_CHECK(clGetDeviceInfo(worker->device_id, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof(worker->global_mem_size), &worker->global_mem_size, NULL));

      // Calculate memory allocation
      cl_ulong memory_size_mb = 0;
      if (memory_sizes_len > 0)
      {
        if (memory_sizes_len == 1)
        {
          memory_size_mb = memory_sizes[0];
        }
        else if (worker_idx < memory_sizes_len)
        {
          memory_size_mb = memory_sizes[worker_idx];
        }
      }
      if (memory_size_mb == 0)
      {
        const cl_ulong memory_size_gb = (is_amd ? worker->max_mem_alloc_size : worker->global_mem_size / 2) / ONE_GB;
        memory_size_mb = memory_size_gb * 1024;
      }

      const cl_ulong nonces_per_run = (memory_size_mb * ONE_MB) / (ARGON2_BLOCK_SIZE * ARGON2_MEMORY_COST);
      const cl_uint memory_cost = ARGON2_MEMORY_COST;
      const cl_uint jobs_per_block = (is_amd ? 2 : 1);
      const size_t shmem_size = THREADS_PER_LANE * 2 * sizeof(cl_uint) * jobs_per_block;

      if (strlen(worker->driver_version) == 0)
      {
        strcpy(worker->driver_version, "?");
      }

      if (strlen(worker->device_version) == 0)
      {
        strcpy(worker->device_version, "?");
      }

      printf("  Device #%u: %s by %s:\n"
             "    Driver %s, OpenCL %s\n"
             "    %u compute units @ %u MHz\n"
             "    Using %lu GB of global memory, nonces per run: %lu\n",
             global_device_idx, worker->device_name, worker->device_vendor,
             worker->driver_version, worker->device_version,
             worker->max_compute_units, worker->max_clock_frequency,
             memory_size_mb, nonces_per_run);

      worker->nonces_per_run = (cl_uint)nonces_per_run;

      worker->context = CL_CHECK_ERR(clCreateContext(NULL, 1, &worker->device_id, NULL, NULL, &_err));

      cl_int mem_err;
      size_t blocks_mem_size = (size_t)(ARGON2_MEMORY_COST + (is_amd ? 1 : 0)) * ARGON2_BLOCK_SIZE * nonces_per_run;
      worker->mem_argon2_blocks = clCreateBuffer(worker->context, CL_MEM_READ_WRITE, blocks_mem_size, NULL, &mem_err);
      if (mem_err != CL_SUCCESS)
      {
        fprintf(stderr, "Failed to allocate required memory.\n");
        return CL_MEM_OBJECT_ALLOCATION_FAILURE;
      }

      worker->mem_initial_seed = CL_CHECK_ERR(clCreateBuffer(worker->context, CL_MEM_READ_WRITE, INITIAL_SEED_SIZE, NULL, &_err));
      worker->mem_nonce = CL_CHECK_ERR(clCreateBuffer(worker->context, CL_MEM_READ_WRITE, sizeof(cl_uint), NULL, &_err));

      worker->program = CL_CHECK_ERR(clCreateProgramWithSource(worker->context, 2, sources, source_lengths, &_err));
      cl_int build_result = clBuildProgram(worker->program, 0, NULL, build_options, NULL, NULL);
      if (build_result != CL_SUCCESS)
      {
        size_t log_size;
        char *log;
        CL_CHECK(clGetProgramBuildInfo(worker->program, worker->device_id, CL_PROGRAM_BUILD_LOG, 0, NULL, &log_size));
        log = malloc(log_size);
        CL_CHECK(clGetProgramBuildInfo(worker->program, worker->device_id, CL_PROGRAM_BUILD_LOG, log_size, log, NULL));
        fprintf(stderr, "Failed to build program: %s\n", log);
        free(log);
        return CL_BUILD_PROGRAM_FAILURE;
      }

      worker->queue = CL_CHECK_ERR(clCreateCommandQueue(worker->context, worker->device_id, 0, &_err));

      worker->kernel_init_memory = CL_CHECK_ERR(clCreateKernel(worker->program, "init_memory", &_err));
      CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 0, sizeof(cl_mem), &worker->mem_initial_seed));
      CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 1, sizeof(cl_mem), &worker->mem_argon2_blocks));
      CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 2, sizeof(cl_uint), &memory_cost));

      worker->kernel_argon2 = CL_CHECK_ERR(clCreateKernel(worker->program, "argon2", &_err));
      CL_CHECK(clSetKernelArg(worker->kernel_argon2, 0, shmem_size, NULL));
      CL_CHECK(clSetKernelArg(worker->kernel_argon2, 1, sizeof(cl_mem), &worker->mem_argon2_blocks));
      CL_CHECK(clSetKernelArg(worker->kernel_argon2, 2, sizeof(cl_uint), &memory_cost));

      worker->kernel_find_nonce = CL_CHECK_ERR(clCreateKernel(worker->program, "find_nonce", &_err));
      // arg 0 is not available yet
      CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 1, sizeof(cl_mem), &worker->mem_argon2_blocks));
      CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 2, sizeof(cl_uint), &memory_cost));
      CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 3, sizeof(cl_mem), &worker->mem_nonce));

      worker->init_memory_global_size[0] = nonces_per_run;
      worker->init_memory_global_size[1] = jobs_per_block;
      worker->init_memory_local_size[0] = NONCES_PER_GROUP;
      worker->init_memory_local_size[1] = jobs_per_block;

      worker->argon2_global_size[0] = THREADS_PER_LANE;
      worker->argon2_global_size[1] = nonces_per_run;
      worker->argon2_local_size[0] = THREADS_PER_LANE;
      worker->argon2_local_size[1] = jobs_per_block;

      worker->find_nonce_global_size[0] = nonces_per_run;
      worker->find_nonce_local_size[0] = NONCES_PER_GROUP;

      worker_idx++;
    }

    free(devices);
  }

  free(platforms);

  if (miner->num_workers < 1)
  {
    fprintf(stderr, "Failed to find any usable GPU devices.\n");
    return CL_DEVICE_NOT_FOUND;
  }

  return CL_SUCCESS;
}

cl_int release_miner(miner_t *miner)
{
  for (cl_uint i = 0; i < miner->num_workers; i++)
  {
    worker_t *worker = &miner->workers[i];
    CL_CHECK(clReleaseKernel(worker->kernel_init_memory));
    CL_CHECK(clReleaseKernel(worker->kernel_argon2));
    CL_CHECK(clReleaseKernel(worker->kernel_find_nonce));
    CL_CHECK(clReleaseMemObject(worker->mem_initial_seed));
    CL_CHECK(clReleaseMemObject(worker->mem_argon2_blocks));
    CL_CHECK(clReleaseMemObject(worker->mem_nonce));
    CL_CHECK(clReleaseProgram(worker->program));
    CL_CHECK(clReleaseCommandQueue(worker->queue));
    CL_CHECK(clReleaseContext(worker->context));
  }
  free(miner->workers);

  return CL_SUCCESS;
}

cl_int setup_worker(worker_t *worker, void *initial_seed)
{
  CL_CHECK(clEnqueueWriteBuffer(worker->queue, worker->mem_initial_seed, CL_FALSE, 0, INITIAL_SEED_SIZE, initial_seed, 0, NULL, NULL));
  CL_CHECK(clEnqueueWriteBuffer(worker->queue, worker->mem_nonce, CL_TRUE, 0, sizeof(cl_uint), &zero, 0, NULL, NULL));
  return CL_SUCCESS;
}

cl_int mine_nonces(worker_t *worker, cl_uint start_nonce, cl_uint share_compact, cl_uint *nonce)
{
  // Initialize memory
  size_t init_memory_global_offset[2] = {start_nonce, 0};
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_init_memory, 2, init_memory_global_offset, worker->init_memory_global_size, worker->init_memory_local_size, 0, NULL, NULL));

  // Compute Argon2d hashes
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_argon2, 2, NULL, worker->argon2_global_size, worker->argon2_local_size, 0, NULL, NULL));

  // Is there PoW?
  size_t find_nonce_global_offset[1] = {start_nonce};
  CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 0, sizeof(cl_uint), &share_compact));
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_find_nonce, 1, find_nonce_global_offset, worker->find_nonce_global_size, worker->find_nonce_local_size, 0, NULL, NULL));

  CL_CHECK(clEnqueueReadBuffer(worker->queue, worker->mem_nonce, CL_TRUE, 0, sizeof(cl_uint), nonce, 0, NULL, NULL));

  if (*nonce > 0)
  {
    CL_CHECK(clEnqueueWriteBuffer(worker->queue, worker->mem_nonce, CL_TRUE, 0, sizeof(cl_uint), &zero, 0, NULL, NULL));
  }

  return CL_SUCCESS;
}
