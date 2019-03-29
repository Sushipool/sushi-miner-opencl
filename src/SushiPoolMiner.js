const Nimiq = require('@nimiq/core');
const WebSocket = require('ws');
const DumbGpuMiner = require('./DumbGpuMiner.js');

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

const GENESIS_HASH_MAINNET = 'Jkqvik+YKKdsVQY12geOtGYwahifzANxC+6fZJyGnRI=';
class SushiPoolMiner extends Nimiq.Observable {

    constructor(pool, address, deviceId, deviceName, deviceData, allowedDevices, memorySizes, threads) {
        super();
        this._ourAddress = address;
        this._pool = pool;
        this._deviceId = deviceId;
        this._deviceName = deviceName;
        this._deviceData = deviceData;
        this._host = pool.host;
        this.on('share', (block, fullValid) => this._onBlockMined(block, fullValid));
        this._startDifficulty = deviceData.startDifficulty;
        this._connect();

        this._miner = new DumbGpuMiner(allowedDevices,  memorySizes, threads);
        this.currentBlockHeader = undefined;
        this.currentTargetCompact = undefined;    
    }

    _connect() {
        Nimiq.Log.i(SushiPoolMiner, `Connecting to ${this._pool.host}:${this._pool.port}`);
        this._ws = new WebSocket(`wss://${this._pool.host}:${this._pool.port}`);

        this._ws.on('open', () => {
            this._register();
        });

        this._ws.on('close', (code, reason) => {
            let timeout = Math.floor(Math.random() * 25) + 5;
            Nimiq.Log.w(SushiPoolMiner, 'Connection lost. Reconnecting in ' + timeout + ' seconds');
            this.fire('disconnected');
            if (!this._closed) {
                setTimeout(() => this._connect(), timeout * 1000);
            }
        });

        this._ws.on('message', (msg) => this._onMessage(JSON.parse(msg)));

        this._ws.on('error', (e) => Nimiq.Log.e(`WS error - ${e.message}`, e));
    }


    _register() {
        const deviceName = this._deviceName || '';
        const minerVersion = this._deviceData._minerVersion;
        Nimiq.Log.i(SushiPoolMiner, `Registering to pool (${this._host}) using device id ${this._deviceId} (${deviceName}) as a dumb client.`);
        this._send({
            message: 'register',
            mode: 'dumb',
            address: this._ourAddress,
            deviceId: this._deviceId,
            startDifficulty: this._deviceData.startDifficulty,
            deviceName: deviceName,
            deviceData: this._deviceData,
            minerVersion: minerVersion,
            genesisHash: GENESIS_HASH_MAINNET
        })
    }


    _onMessage(msg) {
        if (!msg || !msg.message) return;
        switch (msg.message) {
            case 'registered':
                this.fire('connected');
                break;
            case 'settings':
                this.fire('settings', msg.address, Buffer.from(msg.extraData, 'base64'), msg.targetCompact);
                break;
            case 'new-block':
                this.fire('new-block', Buffer.from(msg.blockHeader, 'base64'));
                break;
            case 'error':
                Nimiq.Log.w(`Pool error: ${msg.reason}`);
                break;
        }
    }

    submitShare(nonce) {
        this._send({
            message: 'share',
            nonce
        });
        Nimiq.Log.i(SushiPoolMiner, `Share found, nonce: ${nonce}`);
    }

    _send(msg) {
        try {
            this._ws.send(JSON.stringify(msg));
        } catch (e) {
            const readyState = this._ws.readyState;
            Nimiq.Log.e(`WS error - ${e.message}`);
            if (readyState === 3) {
                this._ws.close();
            }
        }
    }

    mineBlock(resetNonce) {
        if (this.currentBlockHeader && this.currentTargetCompact) {
            this._miner.mine(this.currentBlockHeader, this.currentTargetCompact, resetNonce);
        }
    };

}

module.exports = SushiPoolMiner;
