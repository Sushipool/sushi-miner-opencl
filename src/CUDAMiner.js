const Nimiq = require('@nimiq/core');
const NativeMiner = require('bindings')('nimiq_miner_cuda.node');

// TODO: configurable interval
const HASHRATE_MOVING_AVERAGE = 6; // measurements
const HASHRATE_REPORT_INTERVAL = 10; // seconds

class CUDAMiner extends Nimiq.Observable {

    constructor(deviceOptions) {
        super();

        this._miner = new NativeMiner.Miner();
        this._devices = this._miner.getDevices();
        this._devices.forEach((device, idx) => {
            const options = deviceOptions.forDevice(idx);
            if (!options.enabled) {
                device.enabled = false;
                Nimiq.Log.i(`GPU #${idx}: ${device.name}. Disabled by user.`);
                return;
            }
            if (options.memory !== undefined) {
                device.memory = options.memory;
            }
            if (options.threads !== undefined) {
                device.threads = options.threads;
            }
            if (options.cache !== undefined) {
                device.cache = options.cache;
            }
            if (options.memoryTradeoff !== undefined) {
                device.memoryTradeoff = options.memoryTradeoff;
            }
            Nimiq.Log.i(`GPU #${idx}: ${device.name}, ${device.multiProcessorCount} SM @ ${device.clockRate} MHz. (memory: ${device.memory == 0 ? 'auto' : device.memory}, threads: ${device.threads}, cache: ${device.cache}, mem.tradeoff: ${device.memoryTradeoff})`);
        });

        this._hashes = [];
        this._lastHashRates = [];
    }

    _reportHashRate() {
        const averageHashRates = [];
        this._hashes.forEach((hashes, idx) => {
            const hashRate = hashes / HASHRATE_REPORT_INTERVAL;
            this._lastHashRates[idx] = this._lastHashRates[idx] || [];
            this._lastHashRates[idx].push(hashRate);
            if (this._lastHashRates[idx].length > HASHRATE_MOVING_AVERAGE) {
                this._lastHashRates[idx].shift();
            }
            averageHashRates[idx] = this._lastHashRates[idx].reduce((sum, val) => sum + val, 0) / this._lastHashRates[idx].length;
        });
        this._hashes = [];
        this.fire('hashrate-changed', averageHashRates);
    }

    setShareCompact(shareCompact) {
        this._miner.setShareCompact(shareCompact);
    }

    startMiningOnBlock(blockHeader) {
        if (!this._hashRateTimer) {
            this._hashRateTimer = setInterval(() => this._reportHashRate(), 1000 * HASHRATE_REPORT_INTERVAL);
        }
        this._miner.startMiningOnBlock(blockHeader, (error, obj) => {
            if (error) {
                throw error;
            }
            if (obj.done === true) {
                return;
            }
            if (obj.nonce > 0) {
                this.fire('share', obj.nonce);
            }
            this._hashes[obj.device] = (this._hashes[obj.device] || 0) + obj.noncesPerRun;
        });
    }

    stop() {
        this._miner.stop();
        if (this._hashRateTimer) {
            this._hashes = [];
            this._lastHashRates = [];
            clearInterval(this._hashRateTimer);
            delete this._hashRateTimer;
        }
    }
}

module.exports = CUDAMiner;
