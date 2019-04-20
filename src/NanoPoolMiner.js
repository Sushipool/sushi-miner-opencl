const Nimiq = require('@nimiq/core');
const Miner = require('./Miner');

const SHARE_WATCHDOG_INTERVAL = 180; // seconds

class NanoPoolMiner extends Nimiq.NanoPoolMiner {

    constructor(blockchain, time, address, deviceId, deviceData, allowedDevices, memorySizes, threads) {
        super(blockchain, time, address, deviceId, deviceData);

        this._sharesFound = 0;

        this._miner = new Miner(allowedDevices, memorySizes, threads);
        this._miner.on('share', nonce => {
            this._submitShare(nonce);
        });
        this._miner.on('hashrate-changed', hashrates => {
            this.fire('hashrate-changed', hashrates);
        });
    }

    _startMining() {
        const block = this.getNextBlock();
        if (!block) {
            return;
        }
        this._block = block;

        Nimiq.Log.i(NanoPoolMiner, `Starting work on block #${block.height}`);
        this._miner.startMiningOnBlock(Buffer.from(block.header.serialize()));

        if (!this._shareWatchDog) {
            this._shareWatchDog = setInterval(() => this._checkIfSharesFound(), 1000 * SHARE_WATCHDOG_INTERVAL);
        }
    }

    _stopMining() {
        this._miner.stop();
        if (this._shareWatchDog) {
            clearInterval(this._shareWatchDog);
            delete this._shareWatchDog;
        }
    }

    _register() {
        this._send({
            message: 'register',
            mode: this.mode,
            address: this._ourAddress.toUserFriendlyAddress(),
            deviceId: this._deviceId,
            deviceName: this._deviceData.deviceName,
            deviceData: this._deviceData,
            genesisHash: Nimiq.BufferUtils.toBase64(Nimiq.GenesisConfig.GENESIS_HASH.serialize())
        });
    }

    _onNewPoolSettings(address, extraData, shareCompact, nonce) {
        super._onNewPoolSettings(address, extraData, shareCompact, nonce);
        if (Nimiq.BlockUtils.isValidCompact(shareCompact)) {
            const difficulty = Nimiq.BlockUtils.compactToDifficulty(shareCompact);
            Nimiq.Log.i(NanoPoolMiner, `Set share difficulty: ${difficulty.toFixed(2)} (${shareCompact.toString(16)})`);
            this._miner.setShareCompact(shareCompact);
        } else {
            Nimiq.Log.w(NanoPoolMiner, `Pool sent invalid target: ${shareCompact}`);
        }
    }

    async _handleNewBlock(msg) {
        await super._handleNewBlock(msg);
        this._startMining();
    }

    async _submitShare(nonce) {
        const blockHeader = this._block.header.serialize();
        blockHeader.writePos -= 4;
        blockHeader.writeUint32(nonce);
        const hash = await (await Nimiq.CryptoWorker.getInstanceAsync()).computeArgon2d(blockHeader);
        this.onWorkerShare({
            block: this._block,
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
