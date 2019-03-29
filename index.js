const fs = require('fs');
const os = require('os');
const JSON5 = require('json5');
const pjson = require('./package.json');
const Nimiq = require('@nimiq/core');
const NanoPoolMiner = require('./src/NanoPoolMiner');
const SushiPoolMiner = require('./src/SushiPoolMiner');
const crypto = require('crypto');
const Log = Nimiq.Log;

const TAG = 'Nimiq OpenCL Miner';
const $ = {};

Log.instance.level = 'info';

function humanHashrate(hashes) {
    let thresh = 1000;
    if (Math.abs(hashes) < thresh) {
        return hashes + ' H/s';
    }
    let units = ['kH/s', 'MH/s', 'GH/s', 'TH/s', 'PH/s', 'EH/s', 'ZH/s', 'YH/s'];
    let u = -1;
    do {
        hashes /= thresh;
        ++u;
    } while (Math.abs(hashes) >= thresh && u < units.length - 1);
    return hashes.toFixed(1) + ' ' + units[u];
}

function readConfigFile(fileName) {
    try {
        const config = JSON5.parse(fs.readFileSync(fileName));
        // TODO: Validate
        return config;
    } catch (e) {
        Log.e(TAG, `Failed to read config file ${fileName}: ${e.message}`);
        return false;
    }
}

const config = readConfigFile('./miner.conf');
if (!config) {
    process.exit(1);
}

(async () => {
    const address = config.address;
    const deviceName = config.name || os.hostname();
    const hashrate = (config.hashrate > 0) ? config.hashrate : 100; // 100 kH/s by default
    const desiredSps = 5;
    const startDifficulty = (1e3 * hashrate * desiredSps) / (1 << 16);
    const minerVersion = 'OpenCL Miner ' + pjson.version;
    const deviceData = { deviceName, startDifficulty, minerVersion };

    Log.i(TAG, `Nimiq ${minerVersion} starting`);
    Log.i(TAG, `- pool server      = ${config.host}:${config.port}`);
    Log.i(TAG, `- address          = ${address}`);
    Log.i(TAG, `- device name      = ${deviceName}`);

    const consensusType = config.consensus || 'dumb';
    const setupFunc = { // can add other miner types here
        'dumb': setupSushiPoolMiner,
        'nano': setupNanoPoolMiner
    }
    setupFunc[consensusType](address, config, deviceData);    

})().catch(e => {
    console.error(e);
    process.exit(1);
});

async function setupNanoPoolMiner(addr, config, deviceData) {
    Log.i(TAG, `Setting up setupNanoPoolMiner`);

    Nimiq.GenesisConfig.main();
    const networkConfig = new Nimiq.DumbNetworkConfig();
    $.consensus = await Nimiq.Consensus.nano(networkConfig);
    $.blockchain = $.consensus.blockchain;
    $.network = $.consensus.network;

    const deviceId = Nimiq.BasePoolMiner.generateDeviceId(networkConfig);
    Log.i(TAG, `- device id        = ${deviceId}`);

    const address = Nimiq.Address.fromUserFriendlyAddress(addr);
    $.miner = new NanoPoolMiner($.blockchain, $.network.time, address, deviceId, deviceData,
        config.devices, config.memory, config.threads);

    $.miner.on('share', (block, blockValid) => {
        Log.i(TAG, `Found share. Nonce: ${block.header.nonce}`);
    });
    $.miner.on('hashrates-changed', hashrates => {
        const totalHashRate = hashrates.reduce((a, b) => a + b, 0);
        Log.i(TAG, `Hashrate: ${humanHashrate(totalHashRate)} | ${hashrates.map((hr, idx) => `GPU${idx}: ${humanHashrate(hr)}`).filter(hr => hr).join(' | ')}`);
    });

    $.consensus.on('established', () => {
        Log.i(TAG, `Connecting to ${config.host}`);
        $.miner.connect(config.host, config.port);
    });
    $.consensus.on('lost', () => {
        $.miner.disconnect();
    });

    $.blockchain.on('head-changed', (head) => {
        if ($.consensus.established || head.height % 100 === 0) {
            Log.i(TAG, `Now at block: ${head.height}`);
        }
    });

    $.network.on('peer-joined', (peer) => {
        Log.i(TAG, `Connected to ${peer.peerAddress.toString()}`);
    });
    $.network.on('peer-left', (peer) => {
        Log.i(TAG, `Disconnected from ${peer.peerAddress.toString()}`);
    });

    Log.i(TAG, 'Connecting to Nimiq network');
    $.network.connect();
}

async function getDeviceId() {
    const hostInfo = os.hostname() + '/' + Object.values(os.networkInterfaces()).map(i => i.map(a => a.address + '/' + a.mac).join('/')).join('/');
    const hash = crypto.createHash('sha256');
    hash.update(hostInfo);
    return hash.digest().readUInt32LE(0);
}

async function setupSushiPoolMiner(address, config, deviceData) {
    Log.i(TAG, `Setting up SushiPoolMiner`);

    const poolMining = {
        host: config.host,
        port: config.port
    }
    const deviceId = await getDeviceId();
    $.miner = new SushiPoolMiner(poolMining, address, deviceId, deviceData.deviceName, 
        deviceData, deviceData.startDifficulty, deviceData.minerVersion);

    $.miner.on('connected', () => {
        Log.i(TAG,'Connected to pool');
    });

    $.miner.on('balance', (balance, confirmedBalance) => {
        Log.i(TAG,`Balance: ${balance}, confirmed balance: ${confirmedBalance}`);
    });

    $.miner.on('settings', (address, extraData, targetCompact) => {
        Log.i(TAG,`Share compact: ${targetCompact.toString(16)}`);
        $.miner.currentTargetCompact = targetCompact;
        $.miner.mineBlock(false);
    });

    $.miner.on('new-block', (blockHeader) => {
        const height = blockHeader.readUInt32BE(134);
        const hex = blockHeader.toString('hex');
        Log.i(TAG,`New block #${height}: ${hex}`);

        // Workaround duplicated blocks
        if ($.miner.currentBlockHeader != undefined
            && $.miner.currentBlockHeader.equals(blockHeader)) {
            Log.w(TAG,'The same block arrived once again!');
            return;
        }

        $.miner.currentBlockHeader = blockHeader;
        $.miner.mineBlock(true);
    });
    $.miner.on('disconnected', () => {
        $.miner._miner.stop();
    });
    $.miner.on('error', (reason) => {
        Log.w(TAG,`Pool error: ${reason}`);
    });

    $.miner._miner.on('share', nonce => {
        $.miner.submitShare(nonce);
    });
    $.miner._miner.on('hashrate', hashrates => {
        const totalHashRate = hashrates.reduce((a, b) => a + b);
        const gpuInfo = $.miner._miner.gpuInfo;
        const msg1 = `Hashrate: ${humanHashrate(totalHashRate)} | `;
        const msg2 = hashrates.map((hr, idx) => {
            if (gpuInfo[idx].type === 'CPU') {
                return `${gpuInfo[idx].type}: ${humanHashrate(hr)}`;
            } else {
                return `${gpuInfo[idx].type}${gpuInfo[idx].idx}: ${humanHashrate(hr)}`;
            }
        }).join(' | ');
        const msg = msg1 + msg2;
        Log.i(TAG, msg);
    });


}