## Quickstart (Ubuntu/Debian)

1. Install [Node.js](https://github.com/nodesource/distributions/blob/master/README.md#debinstall).
2. Install `git` and `build-essential`: `sudo apt-get install -y git build-essential`.
3. Install `opencl-headers`: `sudo apt-get install opencl-headers`.
4. Install OpenCL-capable drivers for your GPU ([Nvidia](https://www.nvidia.com/Download/index.aspx) or [AMD](https://www.amd.com/en/support))
5. Clone this repository: `git clone https://github.com/Sushipool/nimiq-opencl-miner`.
6. Build the project: `cd nimiq-opencl-miner && npm install`.
7. Copy sushipool.sample.conf to sushipool.conf: `cp sushipool.sample.conf sushipool.conf`.
8. Edit sushipool.conf, specify your wallet address.
9. Run the miner `UV_THREADPOOL_SIZE=8 nodejs index.js`. Ensure UV_THREADPOOL_SIZE is higher than a number of GPU in your system.

