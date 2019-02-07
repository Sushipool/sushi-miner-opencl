{
    "targets": [
        {
            "target_name": "nimiq_miner",
            "sources": [
                "src/native/argon2d.cl",
                "src/native/blake2b.cl",
                "src/native/miner.c",
                "src/native/nimiq_miner.cc"
            ],
            "include_dirs": [
                "<!(node -e \"require('nan')\")",
                "src/native"
            ],
            "libraries": [
                "-lOpenCL"
            ],
            'conditions': [
            ['OS in "linux freebsd openbsd"', {
              'variables' : {
                'OPENCL_SDK' : '<!(echo $AMDAPPSDKROOT)',
                'OPENCL_SDK_INCLUDE' : '<(OPENCL_SDK)/include',
                'OPENCL_SDK_LIB' : '<(OPENCL_SDK)/lib/x86_64',
              },
              'include_dirs' : [
                "<(OPENCL_SDK_INCLUDE)",
              ],
              'libraries': ['-L<(OPENCL_SDK_LIB)','-lOpenCL'],
              'cflags_cc': [' -Wall','-O3','-fexceptions']
            }],
            ['OS=="win"', {
              'variables' :
                {
                  'AMD_OPENCL_SDK' : '<!(echo %AMDAPPSDKROOT%)',
                  'AMD_OPENCL_SDK_INCLUDE' : '<(AMD_OPENCL_SDK)\\include',
                  'AMD_OPENCL_SDK_LIB' : '<(AMD_OPENCL_SDK)\\lib\\x86_64',
                },
                'include_dirs' : [
                  "<(AMD_OPENCL_SDK_INCLUDE)", "<!(echo %OPENCL_HEADER%)",
                ],
                'library_dirs' : [
                  "<(AMD_OPENCL_SDK_LIB)"
                ],
                'defines' : [
                  'VC_EXTRALEAN',
                ],
                'libraries': ['OpenCL.lib'],
              }

          ]
        ]
        }
    ]
}