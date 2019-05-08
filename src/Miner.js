const Nimiq = require('@nimiq/core');
const NativeMiner = require('bindings')('nimiq_miner_opencl.node');

const INITIAL_SEED_SIZE = 256;
const MAX_NONCE = 2 ** 32;

// TODO: configurable interval
const HASHRATE_MOVING_AVERAGE = 5; // seconds
const HASHRATE_REPORT_INTERVAL = 5; // seconds

const ARGON2_ITERATIONS = 1;
const ARGON2_LANES = 1;
const ARGON2_MEMORY_COST = 512;
const ARGON2_VERSION = 0x13;
const ARGON2_TYPE = 0; // Argon2D
const ARGON2_SALT = 'nimiqrocks!';
const ARGON2_HASH_LENGTH = 32;

class Miner extends Nimiq.Observable {

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

        this._hashes = [];
        this._lastHashRates = [];

        this._miner = miner; // Keep GC away
        this._workers = workers.map(w => {
            const noncesPerRun = w.noncesPerRun;
            const idx = w.deviceIndex;

            return (blockHeader) => {
                const workId = this._workId;
                const next = () => {
                    const startNonce = this._nonce;
                    this._nonce += noncesPerRun;
                    w.mineNonces((error, nonce) => {
                        if (error) {
                            throw error;
                        }
                        this._hashes[idx] = (this._hashes[idx] || 0) + noncesPerRun;
                        // Another block arrived
                        if (workId !== this._workId) {
                            return;
                        }
                        if (nonce > 0) {
                            this.fire('share', nonce);
                        }
                        if (this._miningEnabled && this._nonce < MAX_NONCE) {
                            next();
                        }
                    }, startNonce, this._shareCompact);
                }

                w.setup(this._getInitialSeed(blockHeader));
                next();
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
        return seed;
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
        this._shareCompact = shareCompact;
    }

    startMiningOnBlock(blockHeader) {
        if (!this._shareCompact) {
            throw 'Share compact is not set';
        }
        this._workId++;
        this._nonce = 0;
        this._miningEnabled = true;
        if (!this._hashRateTimer) {
            this._hashRateTimer = setInterval(() => this._reportHashRate(), 1000 * HASHRATE_REPORT_INTERVAL);
        }
        this._workers.forEach(worker => worker(blockHeader));
    }

    stop() {
        this._miningEnabled = false;
        this._miner.close();        
        if (this._hashRateTimer) {
            this._hashes = [];
            this._lastHashRates = [];
            clearInterval(this._hashRateTimer);
            delete this._hashRateTimer;
        }
    }
}

module.exports = Miner;
