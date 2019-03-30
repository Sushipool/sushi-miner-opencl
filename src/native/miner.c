#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "miner.h"

#include "./argon2d_cl.h"
#include "./blake2b_cl.h"

#define VENDOR_AMD "Advanced Micro Devices"
#define VENDOR_NVIDIA "NVIDIA Corporation"

#define ONE_GB 0x40000000L
#define ONE_MB 0x100000L
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
                        uint32_t *enabled_devices, uint32_t enabled_devices_len,
                        uint32_t *memory_sizes, uint32_t memory_sizes_len,
                        uint32_t *threads, uint32_t threads_len)
{
  cl_int ret;
#ifdef _WIN32
  cl_int _err;
#endif
  miner->num_workers = 0;
  miner->workers = NULL;

  cl_uint global_device_idx = 0;
  cl_uint enabled_device_idx = 0;

  // Find all OpenCL platforms
  cl_uint num_platforms;
  cl_platform_id *platforms = NULL;
  CL_CHECK(clGetPlatformIDs(0, NULL, &num_platforms));
  if (num_platforms < 1)
  {
    fprintf(stderr, "Failed to find OpenCL platforms.\n");
    return CL_INVALID_PLATFORM;
  }

  const char *sources[2] = {(char *)argon2d_cl, (char *)blake2b_cl};

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

    // Find all GPU devices
    cl_uint num_devices = 0;
    cl_device_id *devices = NULL;
    ret = clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 0, NULL, &num_devices);
    if (ret == CL_DEVICE_NOT_FOUND || num_devices < 1)
    {
      printf("  No GPU devices found.\n");
      continue;
    }

    devices = (cl_device_id *)malloc(sizeof(cl_device_id) * num_devices);
    CL_CHECK(clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, num_devices, devices, NULL));

    // Iterate over devices, setup workers
    for (cl_uint platform_device_idx = 0; platform_device_idx < num_devices; platform_device_idx++, global_device_idx++)
    {
      cl_device_id device_id = devices[platform_device_idx];
      char device_name[255];
      char device_vendor[255];
      char driver_version[64];
      char device_version[64];
      cl_uint max_compute_units;
      cl_uint max_clock_frequency;
      cl_ulong max_mem_alloc_size;
      cl_ulong global_mem_size;

      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_NAME, sizeof(device_name), &device_name, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_VENDOR, sizeof(device_vendor), &device_vendor, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DRIVER_VERSION, sizeof(driver_version), &driver_version, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_VERSION, sizeof(device_version), &device_version, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(max_compute_units), &max_compute_units, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof(max_clock_frequency), &max_clock_frequency, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(max_mem_alloc_size), &max_mem_alloc_size, NULL));
      CL_CHECK(clGetDeviceInfo(device_id, CL_DEVICE_GLOBAL_MEM_SIZE, sizeof(global_mem_size), &global_mem_size, NULL));

      if (strlen(driver_version) == 0)
      {
        strcpy(driver_version, "?");
      }

      if (strlen(device_version) == 0)
      {
        strcpy(device_version, "?");
      }

      // Check if this device is enabled
      cl_bool enabled = (enabled_devices_len == 0) || (enabled_device_idx < enabled_devices_len && enabled_devices[enabled_device_idx] == global_device_idx);
      if (!enabled)
      {
        printf("  Device #%u: %s by %s:\n    Disabled by user\n", global_device_idx, device_name, device_vendor);
        continue;
      }

      // Calculate memory allocation
      cl_ulong memory_size_mb = 0;
      if (memory_sizes_len > 0)
      {
        if (memory_sizes_len == 1)
        {
          memory_size_mb = memory_sizes[0];
        }
        else if (enabled_device_idx < memory_sizes_len)
        {
          memory_size_mb = memory_sizes[enabled_device_idx];
        }
      }
      if (memory_size_mb == 0)
      {
        const cl_ulong memory_size_gb = (is_amd ? max_mem_alloc_size / ONE_GB : global_mem_size / ONE_GB - 1);
        memory_size_mb = memory_size_gb * 1024;
      }

      // How many threads to run
      cl_uint num_threads = 1;
      if (threads_len > 0)
      {
        if (threads_len == 1)
        {
          num_threads = threads[0];
        }
        else if (enabled_device_idx < threads_len)
        {
          num_threads = threads[enabled_device_idx];
        }
      }
      num_threads = (num_threads > 8) ? 8 : (num_threads < 1) ? 1 : num_threads; // limit to some reasonable value

      const cl_ulong nonces_per_run = (memory_size_mb * ONE_MB) / (ARGON2_BLOCK_SIZE * ARGON2_MEMORY_COST);
      const cl_uint jobs_per_block = (is_amd ? 2 : 1);
      const cl_uint lds_cache_size = (is_amd ? 3 : 2); // Can't be 1
      const size_t shmem_size = (1 + lds_cache_size) * jobs_per_block * ARGON2_BLOCK_SIZE;

      printf("  Device #%u: %s by %s:\n"
             "    Driver %s, %s\n"
             "    %u compute units @ %u MHz\n"
             "    Using %lu MB of global memory, nonces per run: %lu x %u thread(s)\n",
             global_device_idx, device_name, device_vendor,
             driver_version, device_version,
             max_compute_units, max_clock_frequency,
             num_threads * memory_size_mb, nonces_per_run, num_threads);

      cl_context context = CL_CHECK_ERR(clCreateContext(NULL, 1, &device_id, NULL, NULL, &_err));

      char build_options[255];
      strcpy(build_options, "-Werror");
      if (is_amd)
      {
        strcat(build_options, " -DAMD");
      }
      char opt[30];
      if (lds_cache_size > 0)
      {
        sprintf(opt, " -DLDS_CACHE_SIZE=%u", lds_cache_size);
        strcat(build_options, opt);
      }

      cl_program program = CL_CHECK_ERR(clCreateProgramWithSource(context, 2, sources, NULL, &_err));
      cl_int build_result = clBuildProgram(program, 0, NULL, build_options, NULL, NULL);
      if (build_result != CL_SUCCESS)
      {
        size_t log_size;
        char *log;
        CL_CHECK(clGetProgramBuildInfo(program, device_id, CL_PROGRAM_BUILD_LOG, 0, NULL, &log_size));
        log = malloc(log_size);
        CL_CHECK(clGetProgramBuildInfo(program, device_id, CL_PROGRAM_BUILD_LOG, log_size, log, NULL));
        fprintf(stderr, "Failed to build program: %s\n", log);
        free(log);
        return CL_BUILD_PROGRAM_FAILURE;
      }

      // Create workers for this device
      miner->num_workers += num_threads;
      miner->workers = (worker_t *)realloc(miner->workers, sizeof(worker_t) * miner->num_workers);

      for (cl_uint thread_idx = 0; thread_idx < num_threads; thread_idx++)
      {
        worker_t *worker = &miner->workers[miner->num_workers - num_threads + thread_idx];
        worker->device_index = global_device_idx;
        worker->thread_index = thread_idx;
        worker->device_id = device_id;

        strncpy(worker->device_name, device_name, sizeof(worker->device_name));
        strncpy(worker->device_vendor, device_vendor, sizeof(worker->device_vendor));
        strncpy(worker->driver_version, driver_version, sizeof(worker->driver_version));
        strncpy(worker->device_version, device_version, sizeof(worker->device_version));
        worker->max_compute_units = max_compute_units;
        worker->max_clock_frequency = max_clock_frequency;
        worker->max_mem_alloc_size = max_mem_alloc_size;
        worker->global_mem_size = global_mem_size;

        worker->nonces_per_run = (cl_uint)nonces_per_run;

        worker->context = context;
        CL_CHECK(clRetainContext(context));

        worker->program = program;
        CL_CHECK(clRetainProgram(program));

        cl_int mem_err;
        size_t blocks_mem_size = (size_t)nonces_per_run * ARGON2_MEMORY_COST * ARGON2_BLOCK_SIZE;
        worker->mem_argon2_blocks = clCreateBuffer(worker->context, CL_MEM_READ_WRITE, blocks_mem_size, NULL, &mem_err);
        if (mem_err != CL_SUCCESS)
        {
          fprintf(stderr, "Failed to allocate required memory.\n");
          return CL_MEM_OBJECT_ALLOCATION_FAILURE;
        }

        worker->mem_initial_seed = CL_CHECK_ERR(clCreateBuffer(worker->context, CL_MEM_READ_WRITE, INITIAL_SEED_SIZE, NULL, &_err));
        worker->mem_nonce = CL_CHECK_ERR(clCreateBuffer(worker->context, CL_MEM_READ_WRITE, sizeof(cl_uint), NULL, &_err));

        worker->queue = CL_CHECK_ERR(clCreateCommandQueue(worker->context, worker->device_id, 0, &_err));

        worker->kernel_init_memory = CL_CHECK_ERR(clCreateKernel(worker->program, "init_memory", &_err));
        CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 0, sizeof(cl_mem), &worker->mem_argon2_blocks));
        CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 1, sizeof(cl_mem), &worker->mem_initial_seed));

        worker->kernel_argon2 = CL_CHECK_ERR(clCreateKernel(worker->program, "argon2", &_err));
        CL_CHECK(clSetKernelArg(worker->kernel_argon2, 0, shmem_size, NULL));
        CL_CHECK(clSetKernelArg(worker->kernel_argon2, 1, sizeof(cl_mem), &worker->mem_argon2_blocks));

        worker->kernel_find_nonce = CL_CHECK_ERR(clCreateKernel(worker->program, "get_nonce", &_err));
        CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 0, sizeof(cl_mem), &worker->mem_argon2_blocks));
        CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 3, sizeof(cl_mem), &worker->mem_nonce));

        worker->init_memory_global_size[0] = nonces_per_run;
        worker->init_memory_global_size[1] = 2;
        worker->init_memory_local_size[0] = 128;
        worker->init_memory_local_size[1] = 2;

        worker->argon2_global_size[0] = THREADS_PER_LANE;
        worker->argon2_global_size[1] = nonces_per_run;
        worker->argon2_local_size[0] = THREADS_PER_LANE;
        worker->argon2_local_size[1] = jobs_per_block;

        worker->find_nonce_global_size[0] = nonces_per_run;
        worker->find_nonce_local_size[0] = 256;
      }

      CL_CHECK(clReleaseProgram(program));
      CL_CHECK(clReleaseContext(context));

      enabled_device_idx++;
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
  CL_CHECK(clEnqueueWriteBuffer(worker->queue, worker->mem_nonce, CL_FALSE, 0, sizeof(cl_uint), &zero, 0, NULL, NULL));
  return CL_SUCCESS;
}

cl_int mine_nonces(worker_t *worker, cl_uint start_nonce, cl_uint share_compact, cl_uint *nonce)
{
  // Initialize memory
  CL_CHECK(clSetKernelArg(worker->kernel_init_memory, 2, sizeof(cl_uint), &start_nonce));
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_init_memory, 2, NULL, worker->init_memory_global_size, worker->init_memory_local_size, 0, NULL, NULL));

  // Compute Argon2d hashes
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_argon2, 2, NULL, worker->argon2_global_size, worker->argon2_local_size, 0, NULL, NULL));

  // Is there PoW?
  CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 1, sizeof(cl_uint), &start_nonce));
  CL_CHECK(clSetKernelArg(worker->kernel_find_nonce, 2, sizeof(cl_uint), &share_compact));
  CL_CHECK(clEnqueueNDRangeKernel(worker->queue, worker->kernel_find_nonce, 1, NULL, worker->find_nonce_global_size, worker->find_nonce_local_size, 0, NULL, NULL));

  CL_CHECK(clEnqueueReadBuffer(worker->queue, worker->mem_nonce, CL_TRUE, 0, sizeof(cl_uint), nonce, 0, NULL, NULL));

  if (*nonce > 0)
  {
    CL_CHECK(clEnqueueWriteBuffer(worker->queue, worker->mem_nonce, CL_FALSE, 0, sizeof(cl_uint), &zero, 0, NULL, NULL));
  }

  return CL_SUCCESS;
}
