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

exports.readConfigFile = function(fileName) {
    try {
        const config = JSON5.parse(fs.readFileSync(fileName));
        // TODO: Validate
        return config;
    } catch (e) {
        Nimiq.Log.e(`Failed to read config file ${fileName}: ${e.message}`);
        return false;
    }
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