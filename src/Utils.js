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
