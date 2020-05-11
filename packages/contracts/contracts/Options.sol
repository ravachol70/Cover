pragma solidity >=0.6.0 <0.7.0;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { SafeMath } from '@openzeppelin/contracts/math/SafeMath.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { IUniswapV2Router01 } from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol';

import { LiquidityPool } from './LiquidityPool.sol';
import { ILiquidityPool } from './interfaces/ILiquidityPool.sol';
import { ILiquidityPoolFactory } from './interfaces/ILiquidityPoolFactory.sol';


import { IOptions } from './interfaces/IOptions.sol';

import {Option, OptionType, State} from "./Types.sol";

/**
 * @title Option
 * @author Tom Waite, Tom French
 * @dev Base option contract
 * Copyright 2020 Tom Waite, Tom French
 */
abstract contract Options is IOptions, Ownable {
    using SafeMath for uint256;

    Option[] public options; // Array of all created options
    ILiquidityPool public override pool; // Liquidity pool of asset which options will be exercised against
    IERC20 public override paymentToken; // Token for which exercised options will pay in
    IUniswapV2Router01 public override uniswapRouter; // UniswapV2Router01 used to exchange tokens
    OptionType public override optionType; // Does this contract sell put or call options?

    uint constant priceDecimals = 1e8; // number of decimal places in strike price
    uint constant activationDelay = 15 minutes;
    uint256 constant minDuration = 1 days;
    uint256 constant maxDuration = 8 weeks;

    event Create (uint indexed optionId, address indexed account, uint fee, uint premium);
    event Exercise (uint indexed optionId, uint exchangeAmount);
    event Expire (uint indexed optionId);
    event Exchange (uint indexed optionId, address paymentToken, uint inputAmount, address poolToken, uint outputAmount);
    event SetUniswapRouter (address indexed uniswapRouter);
    
    function _internalLock(Option memory option) internal virtual;
    function _internalUnlock(Option memory option) internal virtual;
    function _internalExercise(Option memory option, uint optionID) internal virtual;

    
    constructor(IERC20 poolToken, IERC20 _paymentToken, OptionType t, ILiquidityPoolFactory liquidityPoolFactory) public {
        pool = liquidityPoolFactory.createPool(poolToken);
        paymentToken= _paymentToken;
        optionType = t;

        initialiseUniswap();
    }

    function initialiseUniswap() internal {
        // ropsten addresses
        uniswapRouter = IUniswapV2Router01(0xf164fC0Ec4E93095b804a4795bBe1e041497b92a);
    }

    function setUniswapRouter(address _uniswapRouter) public override onlyOwner {
        uniswapRouter = IUniswapV2Router01(_uniswapRouter);
        emit SetUniswapRouter(_uniswapRouter);
    }

    function poolToken() public override view returns (IERC20) {
        return pool.linkedToken();
    }

    function getOptionsCount() public view returns(uint) {
        return options.length;
    }

    function getOptionInfo(uint optionID) public override view returns (address, uint, uint, uint, uint) {
        Option memory option = options[optionID];
        return (option.holder, option.strikeAmount, option.amount, option.startTime, option.expirationTime);
    }
    
    function fees(/*uint256 duration, uint256 amount, uint256 strikePrice*/) public override pure returns (uint256) {
        return 0;
    }

    /**
      * @dev Create an option to buy pool tokens
      *
      * @param duration the period of time for which the option is valid
      * @param amount [placeholder]
      * @param strikePrice the strike price of the option to be created
      * @return optionID A uint object representing the ID number of the created option.
      */
    function create(uint duration, uint amount, uint strikePrice) internal returns (uint optionID) {
        uint256 fee = 0;
        uint256 premium = 10;

        uint strikeAmount = (strikePrice.mul(amount)).div(priceDecimals);

        require(strikeAmount > 0,"Amount is too small");
        require(fee < premium,  "Premium is too small");
        require(duration >= minDuration, "Duration is too short");
        require(duration <= maxDuration, "Duration is too long");

        // Take ownership of paymentTokens to be paid into liquidity pool.
        require(
          paymentToken.transferFrom(msg.sender, address(this), premium),
          "Insufficient funds"
        );

        // Transfer operator fee
        paymentToken.transfer(owner(), fee);

        // solium-disable-next-line security/no-block-members
        Option memory newOption = Option(State.Active, msg.sender, strikeAmount, amount, now + activationDelay, now + duration);

        optionID = options.length;
        // Exchange paymentTokens into poolTokens to be added to pool
        exchangeTokens(premium, optionID);

        // Lock the assets in the liquidity pool which this asset would be exercised against
        _internalLock(newOption);

        options.push(newOption);

        emit Create(optionID, msg.sender, fee, premium);
        return optionID;
    }


    /// @dev Exercise an option to claim the pool tokens
    /// @param optionID The ID number of the option which is to be exercised
    function exercise(uint optionID) public returns (uint256){
        Option storage option = options[optionID];

        require(option.startTime <= now, 'Options: Option has not been activated yet'); // solium-disable-line security/no-block-members
        require(option.expirationTime >= now, 'Options: Option has expired'); // solium-disable-line security/no-block-members
        require(option.holder == msg.sender, "Options: Wrong msg.sender");
        require(option.state == State.Active, "Options: Can't exercise inactive option");

        option.state = State.Exercised;

        _internalExercise(option, optionID);

        emit Exercise(optionID, option.amount);
        return option.amount;
    }


    /// @dev Unlocks collateral for an array of expired options.
    ///      This is done as they can no longer be exercised.
    /// @param optionIDs An array of IDs for expired options
    function unlockMany(uint[] memory optionIDs) public override {
        for(uint i; i < optionIDs.length; i++) {
            unlock(optionIDs[i]);
        }
    }


    /// @dev Unlocks collateral for an expired option.
    ///      This is done as it can no longer be exercised.
    /// @param optionID The id number of the expired option.
    function unlock(uint optionID) public override {
        Option storage option = options[optionID];

        // Ensure that option is eligible to be nullified
        require(option.expirationTime < now, "Options: Option has not expired yet");
        require(option.state == State.Active, "Options: Option is not active");

        option.state = State.Expired;

        // Unlocks the assets which this option would have been exercised against
        _internalUnlock(option);

        emit Expire(optionID);
    }

    /// @dev Exchange an amount of payment token into the pool token.
    ///      The pool tokens are then sent to the liquidity pool.
    /// @param inputAmount The amount of payment token to be exchanged
    /// @param optionId - unique option identifier, for use in emitting an event and linking
    /// the option exercise to the exchange
    /// @return exchangedAmount The amount of pool tokens sent to the pool
    function exchangeTokens(uint inputAmount, uint optionId) internal returns (uint) {
      require(inputAmount != uint(0), 'Options: Swapping 0 tokens');
      paymentToken.approve(address(uniswapRouter), inputAmount);

      uint deadline = now + 2 minutes;
      address[] memory path = new address[](2);
      path[0] = address(paymentToken);
      path[1] = address(pool.linkedToken());

      uint[] memory exchangeAmount = uniswapRouter.swapExactTokensForTokens(inputAmount, 0, path, address(pool), deadline);

      // exchangeAmount[0] = inputAmount
      // exchangeAmount[i > 0] = subsequent output amounts
      emit Exchange(optionId, address(paymentToken), inputAmount, address(pool.linkedToken()), exchangeAmount[1]);
      return exchangeAmount[1];
    }
}
