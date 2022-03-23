// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./abstract/ReaperBaseStrategyv1_1.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IDeusRewarder.sol";
import "./interfaces/IUniswapV2Router02.sol";
import './interfaces/IUniswapV2Pair.sol';
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "hardhat/console.sol";

/**
 * @dev Deposit LP in MasterChef to harvest and compound rewards.
 */
contract ReaperStrategyLiquidDriverPills is ReaperBaseStrategyv1_1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 3rd-party contract addresses
    address public constant SPIRIT_ROUTER = address(0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52);
    address public constant MASTER_CHEF = address(0x6e2ad6527901c9664f016466b8DA1357a004db0f);

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps.
     * {LQDR} - Reward token.
     * {PILLS} - Dual reward token.
     * {want} - Address of LP token.
     * {lpToken0} - Token 0 of the LP.
     * {lpToken1} - Token 1 of the LP.
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant LQDR = address(0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9);
    address public constant PILLS = address(0xB66b5D38E183De42F21e92aBcAF3c712dd5d6286);
    address public want;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Paths used to swap tokens:
     * {wftmToLP0Route} - to swap {WFTM} to {lpToken0} (using SPIRIT_ROUTER)
     * {wftmToLP1Route} - to swap {WFTM} to {lpToken1} (using SPIRIT_ROUTER)
     */
    address[] public wftmToLP0Route;
    address[] public wftmToLP1Route;

    /**
     * @dev Strategy variables
     * {poolId} - ID of pool in which to deposit LP tokens
     */
    uint256 public poolId;

    /**
     * @dev Initializes the strategy. Sets parameters and saves routes.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address _want,
        uint256 _poolId
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        want = _want;
        poolId = _poolId;

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        // Default paths that can be overridden
        wftmToLP0Route = [WFTM, lpToken0];
        wftmToLP1Route = [WFTM, lpToken1];

        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     *      It gets called whenever someone deposits in the strategy's vault contract.
     */
    function _deposit() internal override {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBalance != 0) {
            IMasterChef(MASTER_CHEF).deposit(poolId, wantBalance, address(this));
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBal < _amount) {
            IMasterChef(MASTER_CHEF).withdraw(poolId, _amount - wantBal, address(this));
        }

        IERC20Upgradeable(want).safeTransfer(vault, _amount);
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     *      1. Claims rewards
     *      2. Swaps rewards to WFTM
     *      3. Claims fees for the harvest caller and treasury
     *      4. Swaps the {WFTM} to make more want token
     *      5. Deposits in the MasterChef
     */
    function _harvestCore() internal override {
        IMasterChef(MASTER_CHEF).harvest(poolId, address(this));
        _swapRewards();
        _chargeFees();
        _addLiquidity();
        _deposit();
    }

    /**
     * @dev Core harvest function. Swaps {LQDR} and {PILLS} balances into {WFTM}.
     */
    function _swapRewards() internal {
        uint256 lqdrBal = IERC20Upgradeable(LQDR).balanceOf(address(this));
        address[] memory lqdrToWftmPath = new address[](2);
        lqdrToWftmPath[0] = LQDR;
        lqdrToWftmPath[1] = WFTM;
        _swap(lqdrBal, lqdrToWftmPath);
        uint256 pillsBal = IERC20Upgradeable(PILLS).balanceOf(address(this));
        address[] memory pillsToWftmPath = new address[](2);
        pillsToWftmPath[0] = PILLS;
        pillsToWftmPath[1] = WFTM;
        _swap(pillsBal, pillsToWftmPath);
    }

    /**
     * @dev Helper function to swap tokens given an {_amount}, swap {_path}.
     */
    function _swap(
        uint256 _amount,
        address[] memory _path
    ) internal {
        if (_path.length < 2 || _amount == 0) {
            return;
        }

        IUniswapV2Router02(SPIRIT_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            0,
            _path,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev Core harvest function.
     *      Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        IERC20Upgradeable wftm = IERC20Upgradeable(WFTM);
        uint256 wftmFee = (wftm.balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint256 callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            wftm.safeTransfer(msg.sender, callFeeToUser);
            wftm.safeTransfer(treasury, treasuryFeeToVault);
            wftm.safeTransfer(strategistRemitter, feeToStrategist);
        }
    }

    /**
     * @dev Core harvest function. Adds more liquidity using {lpToken0} and {lpToken1}.
     */
    function _addLiquidity() internal {
        uint256 wftmBalHalf = IERC20Upgradeable(WFTM).balanceOf(address(this)) / 2;

        if (lpToken0 != WFTM) {
            _swap(wftmBalHalf, wftmToLP0Route);
        }
        if (lpToken1 != WFTM) {
            _swap(wftmBalHalf, wftmToLP1Route);
        }
        uint256 lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));

        if (lp0Bal != 0 && lp1Bal != 0) {
            IUniswapV2Router02(SPIRIT_ROUTER).addLiquidity(
                lpToken0,
                lpToken1,
                lp0Bal,
                lp1Bal,
                0,
                0,
                address(this),
                block.timestamp
            );
        }
    }

    /**
     * @dev Function to calculate the total {want} held by the strat.
     *      It takes into account both the funds in hand, plus the funds in the MasterChef.
     */
    function balanceOf() public view override returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    /** @dev it calculates how much 'want' this contract holds */
    function balanceOfWant() public view returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /** @dev it calculates how much 'want' the strategy has working in the farm */
    function balanceOfPool() public view returns (uint256) {
        (uint256 amount, ) = IMasterChef(MASTER_CHEF).userInfo(poolId, address(this));
        return amount;
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        IMasterChef masterChef = IMasterChef(MASTER_CHEF);
        IDeusRewarder rewarder = IDeusRewarder(masterChef.rewarder(poolId));

        // {LQDR} reward
        uint256 pendingReward = masterChef.pendingLqdr(poolId, address(this));
        uint256 totalRewards = pendingReward + IERC20Upgradeable(LQDR).balanceOf(address(this));
        if (totalRewards != 0) {
            address[] memory lqdrToWftmPath = new address[](2);
            lqdrToWftmPath[0] = LQDR;
            lqdrToWftmPath[1] = WFTM;
            profit += IUniswapV2Router02(SPIRIT_ROUTER).getAmountsOut(totalRewards, lqdrToWftmPath)[1];
        }

        // {PILLS} reward
        pendingReward = rewarder.pendingToken(poolId, address(this));
        totalRewards = pendingReward + IERC20Upgradeable(PILLS).balanceOf(address(this));
        if (totalRewards != 0) {
            address[] memory pillsToWftmPath = new address[](2);
            pillsToWftmPath[0] = PILLS;
            pillsToWftmPath[1] = WFTM;
            profit += IUniswapV2Router02(SPIRIT_ROUTER).getAmountsOut(totalRewards, pillsToWftmPath)[1];
        }

        profit += IERC20Upgradeable(WFTM).balanceOf(address(this));

        uint256 wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        profit -= wftmFee;
    }

    /**
     * @dev Function to retire the strategy. Claims all rewards and withdraws
     *      all principal from external contracts, and sends everything back to
     *      the vault. Can only be called by strategist or owner.
     *
     * Note: this is not an emergency withdraw function. For that, see panic().
     */
    function _retireStrat() internal override {
        _harvestCore();
        IMasterChef(MASTER_CHEF).withdraw(poolId, balanceOfPool(), address(this));
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * Withdraws all funds leaving rewards behind.
     */
    function _reclaimWant() internal override {
        IMasterChef(MASTER_CHEF).emergencyWithdraw(poolId, address(this));
    }

    /**
     * @dev Gives all the necessary allowances to:
     *      - deposit {want} into {MASTER_CHEF}
     *      - swap {LQDR} using {SPIRIT_ROUTER}
     *      - swap {DEUS} using {SPIRIT_ROUTER}
     *      - swap {WFTM} using {SPIRIT_ROUTER}
     *      - add liquidity using {lpToken0} and {lpToken1} in {SPIRIT_ROUTER}
     */
    function _giveAllowances() internal override {
        // want -> MASTER_CHEF
        uint256 wantAllowance = type(uint256).max - IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF);
        IERC20Upgradeable(want).safeIncreaseAllowance(MASTER_CHEF, wantAllowance);
        // LQDR -> SPIRIT_ROUTER
        uint256 lqdrAllowance = type(uint256).max - IERC20Upgradeable(LQDR).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(LQDR).safeIncreaseAllowance(SPIRIT_ROUTER, lqdrAllowance);
        // DEUS -> SPIRIT_ROUTER
        uint256 deusAllowance = type(uint256).max - IERC20Upgradeable(PILLS).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(PILLS).safeIncreaseAllowance(SPIRIT_ROUTER, deusAllowance);
        // WFTM -> SPIRIT_ROUTER
        uint256 wftmAllowance = type(uint256).max - IERC20Upgradeable(WFTM).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(WFTM).safeIncreaseAllowance(SPIRIT_ROUTER, wftmAllowance);

        // lpToken0 -> SPIRIT_ROUTER
        uint256 lp0Allowance = type(uint256).max - IERC20Upgradeable(lpToken0).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(lpToken0).safeIncreaseAllowance(SPIRIT_ROUTER, lp0Allowance);
        // lpToken0 -> SPIRIT_ROUTER
        uint256 lp1Allowance = type(uint256).max - IERC20Upgradeable(lpToken1).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(lpToken1).safeIncreaseAllowance(SPIRIT_ROUTER, lp1Allowance);
    }

    /**
     * @dev Removes all the allowances that were given above.
     */
    function _removeAllowances() internal override {
        IERC20Upgradeable(want).safeDecreaseAllowance(
            MASTER_CHEF,
            IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF)
        );
        IERC20Upgradeable(LQDR).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20Upgradeable(LQDR).allowance(address(this), SPIRIT_ROUTER)
        );
        IERC20Upgradeable(PILLS).safeDecreaseAllowance(
                SPIRIT_ROUTER,
                IERC20Upgradeable(PILLS).allowance(address(this), SPIRIT_ROUTER)
            );
        IERC20Upgradeable(WFTM).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20Upgradeable(WFTM).allowance(address(this), SPIRIT_ROUTER)
        );

        IERC20Upgradeable(lpToken0).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20Upgradeable(lpToken0).allowance(address(this), SPIRIT_ROUTER)
        );
        IERC20Upgradeable(lpToken1).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20Upgradeable(lpToken1).allowance(address(this), SPIRIT_ROUTER)
        );
    }

    function setWftmToLP0Route(
        address[] memory _route
    ) external {
        _onlyStrategistOrOwner();
        require(WFTM == _route[0], "Incorrect path");
        require(lpToken0 == _route[_route.length - 1], "Incorrect path");
        wftmToLP0Route = _route;
    }

    function setWftmToLP1Route(
        address[] memory _route
    ) external {
        _onlyStrategistOrOwner();
        require(WFTM == _route[0], "Incorrect path");
        require(lpToken1 == _route[_route.length - 1], "Incorrect path");
        wftmToLP1Route = _route;
    }
}
