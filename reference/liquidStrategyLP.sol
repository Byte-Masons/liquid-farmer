// SPDX-License-Identifier: MIT

import "./library.sol";
import "./Data.sol";
import "./Interface.sol";

pragma solidity ^0.6.0;

contract liquidStrategyLP is Ownable, Pausable, Data {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    string pendingRewardsFunctionName = "pending output token";

    event StratHarvest(address indexed harvester);

    constructor(
        address _want,
        uint256 _poolId,
        address _masterChef,
        address _output,
        address _unirouter,
        address _sentinel,
        address _grimFeeRecipient,
        address _insuranceFund,
        string memory _pendingRewardsFunctionName
    ) public {
        strategist = msg.sender;
        harvestOnDeposit = true;

        want = _want;
        poolId = _poolId;
        masterchef = _masterChef;
        output = _output;
        unirouter = _unirouter;
        sentinel = _sentinel;
        grimFeeRecipient = _grimFeeRecipient;
        insuranceFund = _insuranceFund;

        outputToWrappedRoute = [output, wrapped];
        outputToWrappedRouter = unirouter;
        wrappedToLp0Router = unirouter;
        wrappedToLp1Router = unirouter;

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        wrappedToLp0Route = [wrapped, lpToken0];
        wrappedToLp1Route = [wrapped, lpToken1];

        pendingRewardsFunctionName = _pendingRewardsFunctionName;

        _giveAllowances();
    }

    /** @dev Sets the grim fee recipient */
    function setGrimFeeRecipient(address _feeRecipient) external {
        require(msg.sender == strategist, "!auth");

        grimFeeRecipient = _feeRecipient;
    }

    /** @dev Sets the vault connected to this strategy */
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    function setDualReward(bool boolean) external onlyOwner {
        dualReward = boolean;
    }

    function dualRewardSetUp(
        address _token,
        address _router,
        address[] memory _toWftmRoute
    ) external onlyOwner {
        dualRewardToken = _token;
        dualRewardRouter = _router;
        dualRewardRoute = _toWftmRoute;
    }

    /** @dev Function to synchronize balances before new user deposit. Can be overridden in the strategy. */
    function beforeDeposit() external virtual {}

    /** @dev Deposits funds into the masterchef */
    function deposit() public whenNotPaused {
        if (balanceOfPool() == 0 || !harvestOnDeposit) {
            _deposit();
        } else {
            _deposit();
            _harvest(msg.sender);
        }
    }

    function _deposit() internal whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IMasterChef(masterchef).deposit(poolId, wantBal, address(this));
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        IMasterChef(masterchef).withdraw(poolId, _amount.sub(wantBal), address(this));
        wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(WITHDRAW_FEE).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external {
        require(msg.sender == strategist, "!auth");

        harvestOnDeposit = _harvestOnDeposit;
    }

    function harvest() external {
        require(!Address.isContract(msg.sender), "!auth Contract Harvest");
        _harvest(msg.sender);
    }

    /** @dev Compounds the strategy's earnings and charges fees */
    function _harvest(address caller) internal whenNotPaused {
        if (caller != vault) {
            require(!Address.isContract(msg.sender), "!auth Contract Harvest");
        }
        IMasterChef(masterchef).harvest(poolId, address(this));
        sellHarvest();
        if (balanceOf() != 0) {
            chargeFees(caller);
            addLiquidity();
        }
        _deposit();

        emit StratHarvest(msg.sender);
    }

    function sellHarvest() internal {
        if (dualReward) {
            uint256 bal = IERC20(dualRewardToken).balanceOf(address(this));
            approveTxnIfNeeded(dualRewardToken, dualRewardRouter, bal);
            IUniSwapRouter(dualRewardRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                bal,
                0,
                dualRewardRoute,
                address(this),
                now
            );
        }
    }

    /** @dev This function converts all funds to WFTM, charges fees, and sends fees to respective accounts */
    function chargeFees(address caller) internal {
        uint256 toWrapped = IERC20(output).balanceOf(address(this));

        IUniSwapRouter(outputToWrappedRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            toWrapped,
            0,
            outputToWrappedRoute,
            address(this),
            now
        );

        uint256 wrappedBal = IERC20(wrapped).balanceOf(address(this)).mul(PLATFORM_FEE).div(MAX_FEE);

        uint256 callFeeAmount = wrappedBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(caller, callFeeAmount);

        uint256 grimFeeAmount = wrappedBal.mul(FEE_BATCH).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(grimFeeRecipient, grimFeeAmount);

        uint256 strategistFee = wrappedBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(strategist, strategistFee);

        uint256 insuranceFee = wrappedBal.mul(INSURANCE_FEE).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(insuranceFund, insuranceFee);
    }

    /** @dev Converts WFTM to both sides of the LP token and builds the liquidity pair */
    function addLiquidity() internal {
        uint256 wrappedHalf = IERC20(wrapped).balanceOf(address(this)).div(2);

        approveTxnIfNeeded(wrapped, wrappedToLp0Router, wrappedHalf);
        approveTxnIfNeeded(wrapped, wrappedToLp1Router, wrappedHalf);

        if (lpToken0 != wrapped) {
            IUniSwapRouter(wrappedToLp0Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wrappedHalf,
                0,
                wrappedToLp0Route,
                address(this),
                now
            );
        }
        if (lpToken1 != wrapped) {
            IUniSwapRouter(wrappedToLp1Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wrappedHalf,
                0,
                wrappedToLp1Route,
                address(this),
                now
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniSwapRouter(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now);
    }

    /** @dev Determines the amount of reward in WFTM upon calling the harvest function */
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            try IUniSwapRouter(unirouter).getAmountsOut(outputBal, outputToWrappedRoute) returns (
                uint256[] memory amountOut
            ) {
                nativeOut = amountOut[amountOut.length - 1];
            } catch {}
        }
        return nativeOut.mul(PLATFORM_FEE).div(MAX_FEE).mul(CALL_FEE).div(MAX_FEE);
    }

    /** @dev Returns the amount of rewards that are pending */
    function rewardsAvailable() public view returns (uint256) {
        string memory signature = StringUtils.concat(pendingRewardsFunctionName, "(uint256,address)");
        bytes memory result = Address.functionStaticCall(
            masterchef,
            abi.encodeWithSignature(signature, poolId, address(this))
        );
        return abi.decode(result, (uint256));
    }

    /** @dev calculate the total underlaying 'want' held by the strat */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    /** @dev it calculates how much 'want' this contract holds */
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /** @dev it calculates how much 'want' the strategy has working in the farm */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(poolId, address(this));
        return _amount;
    }

    /** @dev called as part of strat migration. Sends all the available funds back to the vault */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        IMasterChef(masterchef).emergencyWithdraw(poolId, address(this));
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    /** @dev Pauses the strategy contract and executes the emergency withdraw function */
    function panic() public {
        require(msg.sender == strategist || msg.sender == sentinel, "!auth");
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId, address(this));
    }

    /** @dev Pauses the strategy contract */
    function pause() public {
        require(msg.sender == strategist || msg.sender == sentinel, "!auth");
        _pause();
        _removeAllowances();
    }

    /** @dev Unpauses the strategy contract */
    function unpause() external {
        require(msg.sender == strategist || msg.sender == sentinel, "!auth");
        _unpause();
        _giveAllowances();
        deposit();
    }

    /** @dev Gives allowances to spenders */
    function _giveAllowances() internal {
        IERC20(want).safeApprove(masterchef, uint256(-1));
        IERC20(output).safeApprove(outputToWrappedRouter, uint256(-1));
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));
        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    /** @dev Removes allowances to spenders */
    function _removeAllowances() internal {
        IERC20(want).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(outputToWrappedRouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /** @dev Modular function to set the output to wrapped route */
    function setOutputToWrappedRoute(address[] memory _route, address _router) external {
        require(msg.sender == strategist, "!auth");

        outputToWrappedRoute = _route;
        outputToWrappedRouter = _router;
    }

    /** @dev Modular function to set the transaction route of LP token 0 */
    function setWrappedToLp0Route(address[] memory _route, address _router) external {
        require(msg.sender == strategist, "!auth");

        wrappedToLp0Route = _route;
        wrappedToLp0Router = _router;
    }

    /** @dev Modular function to set the transaction route of LP token 1 */
    function setWrappedToLp1Route(address[] memory _route, address _router) external {
        require(msg.sender == strategist, "!auth");

        wrappedToLp1Route = _route;
        wrappedToLp1Router = _router;
    }

    /** @dev Internal function to approve the transaction if the allowance is below transaction amount */
    function approveTxnIfNeeded(
        address _token,
        address _spender,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeApprove(_spender, uint256(0));
            IERC20(_token).safeApprove(_spender, uint256(-1));
        }
    }

    /** @dev Function to set the fee amounts up to a maximum of five percent */
    function setFees(
        uint256 newCallFee,
        uint256 newStratFee,
        uint256 newWithdrawFee,
        uint256 newFeeBatchAmount,
        uint256 newInsuranceFeeAmount
    ) external {
        require(msg.sender == strategist, "!auth");
        require(newWithdrawFee < 2000, "withdrawal fee too high");
        CALL_FEE = newCallFee;
        STRATEGIST_FEE = newStratFee;
        WITHDRAW_FEE = newWithdrawFee;
        FEE_BATCH = newFeeBatchAmount;
        INSURANCE_FEE = newInsuranceFeeAmount;
    }
}
