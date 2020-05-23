const { use, expect } = require('chai');
const {
    solidity,
    MockProvider,
    createFixtureLoader,
} = require('ethereum-waffle');
const { bigNumberify, Interface } = require('ethers/utils');
const { generalTestFixture } = require('../helpers/fixtures');

const Options = require('../../build/Options.json');
const { VALID_DURATION } = require('../helpers/constants');

const { contextForOptionHasActivated } = require('../helpers/contexts');

use(solidity);

describe.skip('Exchange token, via Uniswap', async () => {
    let poolToken;
    let paymentToken;
    let liquidityPool;
    let optionsContract;
    const numPoolTokens = 2000;
    const numPaymentTokens = 2000;

    const provider = new MockProvider({ gasLimit: 9999999 });
    const [liquidityProvider, optionsBuyer] = provider.getWallets();

    const loadFixture = createFixtureLoader(provider, [
        liquidityProvider,
        optionsBuyer,
    ]);

    beforeEach(async () => {
        // Deploy and link together Options contract, liquidity pool and Uniswap. Extract relevant ERC20s
        ({
            liquidityPool,
            optionsContract,
            poolToken,
            paymentToken,
        } = await loadFixture(generalTestFixture));

        // Give liquidityProvider tokens to buy deposit into pool
        await poolToken.mint(liquidityProvider.address, numPoolTokens);
        await poolToken.approve(liquidityPool.address, numPoolTokens);
        await liquidityPool.deposit(numPoolTokens);

        // Give optionsBuyer tokens to buy option with
        await paymentToken.mint(optionsBuyer.address, numPaymentTokens);
        await paymentToken
            .connect(optionsBuyer)
            .approve(optionsContract.address, numPaymentTokens);
    });

    describe('buyOption', async () => {
        it('should exchange tokens when option is created', async () => {
            const optionValue = 100;
            const premium = 10; // amount being swapped
            const duration = VALID_DURATION.asSeconds();
            const optionId = bigNumberify(0);

            const initialPoolBalance = await liquidityPool.getPoolERC20Balance();

            await expect(optionsContract.createATM(duration, optionValue, 1))
                .to.emit(optionsContract, 'Exchange')
                .withArgs(
                    optionId,
                    paymentToken.address,
                    premium,
                    poolToken.address,
                    4 // TODO: calculate generally
                );
            const finalPoolBalance = await liquidityPool.getPoolERC20Balance();
            expect(finalPoolBalance).to.equal(
                initialPoolBalance.add(bigNumberify(4))
            );
        });
    });

    describe('exerciseOption', async () => {
        let optionID;
        let optionValue;
        const OptionsInterface = new Interface(Options.abi);

        beforeEach(async () => {
            optionValue = 100;
            const tx = await optionsContract.createATM(
                VALID_DURATION.asSeconds(),
                optionValue,
                1
            );
            // Extract optionID from emitted event.
            const receipt = await tx.wait();
            optionID = OptionsInterface.parseLog(
                receipt.logs[receipt.logs.length - 1]
            ).values.optionId;
        });

        contextForOptionHasActivated(provider, function () {
            it('should exchange tokens when an option is exercised', async () => {
                // Note: This test doesn't generalise to put options. See comment on last `expect`
                const [
                    ,
                    ,
                    strikeAmount,
                    amount,
                    ,
                    ,
                    ,
                ] = await optionsContract.getOptionInfo(optionID);

                const initialPoolBalance = await liquidityPool.getPoolERC20Balance();

                await expect(optionsContract.exercise(optionID))
                    .to.emit(optionsContract, 'Exchange')
                    .withArgs(
                        optionID,
                        paymentToken.address,
                        strikeAmount,
                        poolToken.address,
                        51 // TODO: generalise/calculate this expected output
                    )
                    .to.emit(optionsContract, 'Exercise')
                    .withArgs(optionID, optionValue);

                const finalPoolBalance = await liquidityPool.getPoolERC20Balance();

                // Note: finalPoolBalance = initialPoolBalance + uniswap output - funds released to option holder
                // For call options this is option.amount but for put options this is option.strikeAmount
                expect(finalPoolBalance).to.equal(
                    initialPoolBalance.add(51).sub(amount)
                );
            });
        });
    });
});
