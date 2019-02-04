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
            ]
        }
    ]
}