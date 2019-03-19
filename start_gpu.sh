#!/bin/bash

echo "------------------------START Miner----------------------"
export UV_THREADPOOL_SIZE=12
./sushipool-opencl-miner
echo "------------------------END Miner----------------------"
echo "something went wrong or you exited"
