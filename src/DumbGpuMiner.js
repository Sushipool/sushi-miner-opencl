const Nimiq = require('@nimiq/core');
const NativeMiner = require('bindings')('nimiq_miner.node');

const INITIAL_SEED_SIZE = 256;
const MAX_NONCE = 2 ** 32;
const HASHRATE_MOVING_AVERAGE = 5; // seconds
const HASHRATE_REPORT_INTERVAL = 5; // seconds

const ARGON2_ITERATIONS = 1;
const ARGON2_LANES = 1;
const ARGON2_MEMORY_COST = 512;
const ARGON2_VERSION = 0x13;
const ARGON2_TYPE = 0; // Argon2D
const ARGON2_SALT = 'nimiqrocks!';
const ARGON2_HASH_LENGTH = 32;

class DumbGpuMiner extends Nimiq.Observable {

    constructor(allowedDevices, memorySizes, threads) {
        super();

        this._miningEnabled = false;
        this._nonce = 0;
        this._workId = 0;

        allowedDevices = Array.isArray(allowedDevices) ? allowedDevices : [];
        memorySizes = Array.isArray(memorySizes) ? memorySizes : [];
        threads = Array.isArray(threads) ? threads : [];

        const miner = new NativeMiner.Miner(allowedDevices, memorySizes, threads);
        const workers = miner.getWorkers();

        this._hashes = new Array(workers.length).fill(0);
        this._lastHashRates = this._hashes.map(_ => []);

        this._miner = miner;
        this._workers = workers.map((w, idx) => {
            const noncesPerRun = w.noncesPerRun;

            return (blockHeader, shareCompact) => {
                const workId = this._workId;
                const next = () => {
                    //console.log(`@Nonce ${this._nonce}`);
                    const startNonce = this._nonce;
                    this._nonce += noncesPerRun;
                    w.mineNonces((error, nonce) => {
                        if (error) {
                            throw error;
                        }
                        this._hashes[idx] += noncesPerRun;
                        // Another block arrived
                        if (workId !== this._workId) {
                            //console.log(`Stopped working on stale block, work id #${workId}`);
                            return;
                        }
                        if (nonce !== 0) {
                            this.fire('share', nonce);
                        }
                        if (this._miningEnabled && this._nonce < MAX_NONCE) {
                            next();
                        }
                    }, startNonce);
                };

                w.setup(this._getInitialSeed(blockHeader), shareCompact);
                next();
            };
        });
        this._gpuInfo = workers.map(w => {
            return {
                idx: w.deviceIndex,
                name: w.deviceName,
                vendor: w.deviceVendor,
                driver: w.driverVersion,
                computeUnits: w.maxComputeUnits,
                clockFrequency: w.maxClockFrequency,
                memSize: w.globalMemSize,
                type: 'GPU'
            };
        });
    }

    _getInitialSeed(blockHeader) {
        const seed = Buffer.alloc(INITIAL_SEED_SIZE);
        seed.writeUInt32LE(ARGON2_LANES, 0);
        seed.writeUInt32LE(ARGON2_HASH_LENGTH, 4);
        seed.writeUInt32LE(ARGON2_MEMORY_COST, 8);
        seed.writeUInt32LE(ARGON2_ITERATIONS, 12);
        seed.writeUInt32LE(ARGON2_VERSION, 16);
        seed.writeUInt32LE(ARGON2_TYPE, 20);
        seed.writeUInt32LE(blockHeader.length, 24);
        blockHeader.copy(seed, 28);
        seed.writeUInt32LE(ARGON2_SALT.length, 174);
        seed.write(ARGON2_SALT, 178, 'ascii');
        seed.writeUInt32LE(0, 189);
        seed.writeUInt32LE(0, 193);
        // zero padding 59 bytes
        return seed;
    }

    _reportHashRate() {
        this._lastHashRates.forEach((hashRates, idx) => {
            const hashRate = this._hashes[idx] / HASHRATE_REPORT_INTERVAL;
            hashRates.push(hashRate);
            if (hashRates.length > HASHRATE_MOVING_AVERAGE) {
                hashRates.shift();
            }
        });
        this._hashes.fill(0);
        const averageHashRates = this._lastHashRates.map(hashRates => hashRates.reduce((sum, val) => sum + val, 0) / hashRates.length);
        this.fire('hashrate', averageHashRates);
    }

    mine(blockHeader, shareCompact, resetNonce = true) {
        this._workId++;
        if (resetNonce) {
            this._nonce = 0;
        }
        this._miningEnabled = true;

        if (!this._hashRateTimer) {
            this._hashRateTimer = setInterval(() => this._reportHashRate(), 1000 * HASHRATE_REPORT_INTERVAL);
        }

        //console.log(`Started miner on block #${blockHeader.readUInt32BE(134)}, work id #${this._workId}`);
        this._workers.forEach(worker => worker(blockHeader, shareCompact));
    }

    stop() {
        this._miningEnabled = false;
        if (this._hashRateTimer) {
            clearInterval(this._hashRateTimer);
            delete this._hashRateTimer;
        }
    }

    get gpuInfo() {
        return this._gpuInfo;
    }
}

module.exports = DumbGpuMiner;
