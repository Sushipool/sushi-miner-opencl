const os = require('os');
const pjson = require('./package.json');
const Nimiq = require('@nimiq/core');
const Utils = require('./src/Utils');
const NanoPoolMiner = require('./src/NanoPoolMiner');
const DumbPoolMiner = require('./src/DumbPoolMiner');
const Log = Nimiq.Log;

const TAG = 'SushiMiner';
const $ = {};

Log.instance.level = 'info';

const config = Utils.readConfigFile('./miner.conf');
if (!config) {
    process.exit(1);
}

(async () => {
    const address = config.address;
    const deviceName = config.name || os.hostname();
    const hashrate = (config.hashrate > 0) ? config.hashrate : 100; // 100 kH/s by default
    const desiredSps = 5;
    const startDifficulty = (1e3 * hashrate * desiredSps) / (1 << 16);
    const minerVersion = 'Sushi Miner ' + pjson.version + ' OpenCL';
    const deviceData = { deviceName, startDifficulty, minerVersion };
    const deviceOptions = Utils.getDeviceOptions(config);

    // if not specified in the config file, defaults to dumb to make LTD happy :)
    const consensusType = config.consensus || (config.host.toLowerCase().includes('sushipool') ? 'dumb' : 'nano');

    const setup = { // can add other miner types here
        'dumb': setupDumbPoolMiner,
        'nano': setupNanoPoolMiner
    };
    const createMiner = setup[consensusType];
    if (!createMiner) {
        throw new Error(`Wrong consensus type: ${consensusType}`);
    }

    Log.i(TAG, `Nimiq ${minerVersion} starting`);
    Log.i(TAG, `- pool server      = ${config.host}:${config.port}`);
    Log.i(TAG, `- address          = ${address}`);
    Log.i(TAG, `- consensus        = ${consensusType}`);
    Log.i(TAG, `- device name      = ${deviceName}`);

    await createMiner(address, config, deviceData, deviceOptions);

})().catch(e => {
    console.error(e);
    process.exit(1);
});

function reportHashrates(hashrates) {
    const totalHashRate = hashrates.reduce((a, b) => a + b, 0);
    Log.i(TAG, `Hashrate: ${Utils.humanHashrate(totalHashRate)} | ${hashrates.map((hr, idx) => `GPU${idx}: ${Utils.humanHashrate(hr)}`).filter(hr => hr).join(' | ')}`);
}

async function setupNanoPoolMiner(addr, config, deviceData, deviceOptions) {
    Log.i(TAG, `Setting up NanoPoolMiner`);

    Nimiq.GenesisConfig.main();
    const networkConfig = new Nimiq.DumbNetworkConfig();
    $.consensus = await Nimiq.Consensus.nano(networkConfig);
    $.blockchain = $.consensus.blockchain;
    $.network = $.consensus.network;

    const deviceId = Nimiq.BasePoolMiner.generateDeviceId(networkConfig);
    Log.i(TAG, `- device id        = ${deviceId}`);

    const address = Nimiq.Address.fromUserFriendlyAddress(addr);
    $.miner = new NanoPoolMiner($.blockchain, $.network.time, address, deviceId, deviceData, deviceOptions);
    $.miner.on('share', (block, blockValid) => {
        Log.i(TAG, `Found share. Nonce: ${block.header.nonce}`);
    });
    $.miner.on('hashrate-changed', reportHashrates);

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

async function setupDumbPoolMiner(address, config, deviceData, deviceOptions) {
    Log.i(TAG, `Setting up DumbPoolMiner`);

    $.miner = new DumbPoolMiner(address, deviceData, deviceOptions);
    $.miner.on('share', nonce => {
        Log.i(TAG, `Found share. Nonce: ${nonce}`);
    });
    $.miner.on('hashrate-changed', reportHashrates);
    $.miner.connect(config.host, config.port);
}