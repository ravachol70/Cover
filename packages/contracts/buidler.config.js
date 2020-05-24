const { usePlugin } = require('@nomiclabs/buidler/config');

usePlugin('@nomiclabs/buidler-etherscan');
require('dotenv').config({ path: '.env.development' });

usePlugin('@nomiclabs/buidler-waffle');


module.exports = {
    solc: {
        version: '0.6.6',
        optimizer: {
            enabled: true,
            runs: 200,
        },
    },
    mocha: {
        bail: true,
        enableTimeouts: false,
        reporter: 'spec',
    },
    networks: {
        buidlerevm: {
            gas: 9900000,
        },
        ropsten: {
            url: `https://ropsten.infura.io/v3/${process.env.INFURA_API_KEY}`,
            chainId: 3,
            from: process.env.TESTING_ACCOUNT,
            accounts: [process.env.TESTING_ACCOUNT],
            // gas: 5500000,
            gasPrice: 10000000000,
        },
        buidlerevm: {
            gas: 20000000,
            blockGasLimit: 20000000,
        }
    },
    etherscan: {
        url: 'https://api-rinkeby.etherscan.io/api',
        apiKey: process.env.ETHERSCAN_API_KEY,
    },
};
