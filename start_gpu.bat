@echo off
echo "------------------------START Miner----------------------"
SET UV_THREADPOOL_SIZE=24 
sushipool-opencl-miner.exe
echo "------------------------END Miner----------------------"
echo "Something went wrong or you exited"
pause