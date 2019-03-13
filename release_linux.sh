#!/usr/bin/env bash
CURPATH=$(pwd)

# prerequisite:
# using node 10
# npm install pkg@4.3.7 -g

echo "Compiling miner for distribution"
export PACKAGING="1" # set to 1 so nimiq builds the optimised node files for all cpus

rm -rf node_modules
yarn
npm link @nimiq/core
rm -rf dist
mkdir dist
pkg -t node10-linux index.js
mv index dist/sushipool-gpu-miner

cp node_modules/leveldown/build/Release/leveldown.node dist/
cp node_modules/cpuid-git/build/Release/cpuid.node dist/
cp node_modules/@nimiq/core/build/Release/*.node dist/
cp dist/nimiq_node_compat.node dist/nimiq_node_sse2.node
rm dist/nimiq_node_native.node
cp miner.sample.conf dist

echo "Create tar.gz"
cd dist/
tar cvzf ../sushipool-gpu-miner-1.0.5.tar.gz .
cd ..
read -p "Press [Enter] key to quit"