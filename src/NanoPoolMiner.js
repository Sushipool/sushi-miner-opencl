const Nimiq = require('@nimiq/core');
const NativeMiner = require('bindings')('nimiq_miner.node');

const INITIAL_SEED_SIZE = 256;
const MAX_NONCE = 2 ** 32;
const HASHRATE_MOVING_AVERAGE = 5; // seconds
const HASHRATE_REPORT_INTERVAL = 5; // seconds

const SHARE_WATCHDOG_INTERVAL = 180; // seconds

const ARGON2_ITERATIONS = 1;
const ARGON2_LANES = 1;
const ARGON2_MEMORY_COST = 512;
const ARGON2_VERSION = 0x13;
const ARGON2_TYPE = 0; // Argon2D
const ARGON2_SALT = 'nimiqrocks!';
const ARGON2_HASH_LENGTH = 32;

class NanoPoolMiner extends Nimiq.NanoPoolMiner {

    constructor(blockchain, time, address, deviceId, deviceData, allowedDevices, memorySizes, threads) {
        super(blockchain, time, address, deviceId, deviceData);

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
        this._sharesFound = 0;

        this._miner = miner; // Keep GC away
        this._workers = workers.map(w => {
            const noncesPerRun = w.noncesPerRun;
            const idx = w.deviceIndex;

            return (block) => {
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
                            this._submitShare(block, nonce);
                        }
                        if (this._miningEnabled && this._nonce < MAX_NONCE) {
                            next();
                        }
                    }, startNonce, this.shareCompact);
                }

                w.setup(this._getInitialSeed(block.header.serialize()));
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
        Buffer.from(blockHeader).copy(seed, 28);
        seed.writeUInt32LE(ARGON2_SALT.length, 174);
        seed.write(ARGON2_SALT, 178, 'ascii');
        return seed;
    }

    _reportHashRates() {
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
        this.fire('hashrates-changed', averageHashRates);
    }

    _startMining() {
        this._workId++;
        this._nonce = 0;
        this._miningEnabled = true;
        if (!this._hashRateTimer) {
            this._hashRateTimer = setInterval(() => this._reportHashRates(), 1000 * HASHRATE_REPORT_INTERVAL);
        }
        if (!this._shareWatchDog) {
            this._shareWatchDog = setInterval(() => this._checkIfSharesFound(), 1000 * SHARE_WATCHDOG_INTERVAL);
        }

        const block = this.getNextBlock();
        if (!block) {
            return;
        }
        Nimiq.Log.i(NanoPoolMiner, `Starting work on block #${block.height}`);
        this._workers.forEach(worker => worker(block));
    }

    _stopMining() {
        this._miningEnabled = false;
        if (this._hashRateTimer) {
            this._hashes = [];
            this._lastHashRates = [];
            clearInterval(this._hashRateTimer);
            delete this._hashRateTimer;
        }
        if (this._shareWatchDog) {
            clearInterval(this._shareWatchDog);
            delete this._shareWatchDog;
        }
    }

    _onNewPoolSettings(address, extraData, shareCompact, nonce) {
        super._onNewPoolSettings(address, extraData, shareCompact, nonce);
        if (Nimiq.BlockUtils.isValidCompact(shareCompact)) {
            const difficulty = Nimiq.BlockUtils.compactToDifficulty(shareCompact);
            Nimiq.Log.i(NanoPoolMiner, `Set share difficulty: ${difficulty.toFixed(2)} (${shareCompact.toString(16)})`);
        } else {
            Nimiq.Log.w(NanoPoolMiner, `Pool sent invalid target: ${shareCompact}`);
        }
    }

    async _handleNewBlock(msg) {
        await super._handleNewBlock(msg);
        this._startMining();
    }

    async _submitShare(block, nonce) {
        const blockHeader = block.header.serialize();
        blockHeader.writePos -= 4;
        blockHeader.writeUint32(nonce);
        const hash = await (await Nimiq.CryptoWorker.getInstanceAsync()).computeArgon2d(blockHeader);
        this.onWorkerShare({
            block,
            nonce,
            hash: new Nimiq.Hash(hash)
        });
    }

    _onBlockMined(block) {
        super._onBlockMined(block);
        this._sharesFound++;
    }

    _checkIfSharesFound() {
        Nimiq.Log.d(NanoPoolMiner, `Shares found since the last check: ${this._sharesFound}`);
        if (this._sharesFound > 0) {
            this._sharesFound = 0;
            return;
        }
        Nimiq.Log.w(NanoPoolMiner, `No shares have been found for the last ${SHARE_WATCHDOG_INTERVAL} seconds. Reconnecting.`);
        this._timeoutReconnect();
    }

    _turnPoolOff() {
        super._turnPoolOff();
        this._stopMining();
    }
}

module.exports = NanoPoolMiner;
