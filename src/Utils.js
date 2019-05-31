const os = require('os');
const fs = require('fs');
const JSON5 = require('json5');
const Nimiq = require('@nimiq/core');

exports.humanHashrate = function(hashes) {
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

exports.stdConfig = {
    address: 'NQ32 473Y R5T3 979R 325K S8UT 7E3A NRNS VBX2',
    host: 'eu.sushipool.com',
    port: '443',
    name: os.hostname(),
    consensus: 'dumb',
    hashrate: 100,
    devices: [0],
    memory: [2048],
    threads: [2],
    cache: [3],
}

// https://regex101.com/r/hpK5w8/2
exports.validateAddress = function(addr) {
    const r = /(NQ[0-9]{2}\s(?:[a-zA-Z0-9]{4}\s?){8})/;
    const res = r.exec(addr);
    return res && res.length > 0;
}

exports.validateConfigFile = function(cfg) {
    if (!exports.validateAddress(cfg.address)) {
        throw new Error(`Could not validate address: '${cfg.address}'`);
    }

    if (['eu', 'us', 'asia'].indexOf(cfg.host.split('.')[0])) {
        throw new Error(`Could not validate host: '${cfg.host}'`);
    }

    if (cfg.port !== '443') {
        throw new Error(`Please use port '443' got '${cfg.port}'`);
    }

    if (cfg.name === '') {
        throw new Error(`Please set a useful name of your miner, cannot be empty like provided`);
    }

    const consensuses = ['dumb', 'nano', 'light'];
    if (!cfg.consensus.match(/^(dumb|nano|light)$/)) {
        throw new Error(`Please use one of '${consensuses.join(', ')}'; got ${cfg.consensus}`);
    }

    if (parseFloat(cfg.hashrate).toString() === cfg.hashrate) {
        throw new Error(`Could not parse hashrate of ${cfg.hashrate}`);
    }

    const allTrue = (e) => e === true;

    [
        'devices',
        'memory',
        'threads',
        'cache',
    ]
        .map((x) => {
            if (cfg[x] && !cfg[x].map((d) => d > -1).every(allTrue)) {
                throw new Error(`'${x}' needs to be an array of positive integers; got '${cfg[x].join(', ')}'`);
            }
        })
}

exports.readConfigFile = function(fileName, watchCB) {
    try {
        const config = JSON5.parse(fs.readFileSync(fileName));
        exports.validateConfigFile(config);

        if (typeof watchCB === 'function') {
            exports.watchConfigFile.apply(this, [filename, watchCB]);
        }

        return config;
    } catch (e) {
        Nimiq.Log.e(`Failed to read config file ${fileName}: ${e.message}`);
        return false;
    }
}

exports.watchConfigFile = function(fileName, cb) {
    fs.watchFile(fileName, () => {
        const cfg = readConfigFile(filename);
        if (cfg === false) {
            return;
        }

        cb(cfg);
    });
}

exports.getNewHost = function(currentHost) {
    const FALLBACK_HOSTS = [
        'eu.sushipool.com',
        'us.sushipool.com',
        'asia.sushipool.com'
    ];
    let idx = FALLBACK_HOSTS.indexOf(currentHost);
    if (idx !== -1) {
        // if current host is found in fallback hosts, then try the next one
        idx = (idx + 1) % FALLBACK_HOSTS.length; 
    } else { // otherwise just randomly choose one fallback host
        idx = Math.floor(Math.random() * FALLBACK_HOSTS.length);
    }
    const newHost = FALLBACK_HOSTS[idx];
    return newHost;
}