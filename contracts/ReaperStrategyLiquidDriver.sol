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
 * @dev Deposit TOMB-MAI LP in TShareRewardsPool. Harvest TSHARE rewards and recompound.
 */
contract ReaperStrategyLiquidDriver is ReaperBaseStrategyv1_1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 3rd-party contract addresses
    address public constant SPIRIT_ROUTER = address(0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52);
    address public constant MASTER_CHEF = address(0x6e2ad6527901c9664f016466b8DA1357a004db0f);

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps.
     * {TSHARE} - Reward token for depositing LP into TShareRewardsPool.
     * {want} - Address of TOMB-MAI LP token. (lowercase name for FE compatibility)
     * {lpToken0} - TOMB (name for FE compatibility)
     * {lpToken1} - MAI (name for FE compatibility)
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant LQDR = address(0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9);
    address public constant DEUS = address(0xDE5ed76E7c05eC5e4572CfC88d1ACEA165109E44);
    address public want;

    /**
     * @dev Paths used to swap tokens:
     * {tshareToWftmPath} - to swap {TSHARE} to {WFTM} (using SPOOKY_ROUTER)
     * {wftmToTombPath} - to swap {WFTM} to {lpToken0} (using SPOOKY_ROUTER)
     * {tombToMaiPath} - to swap half of {lpToken0} to {lpToken1} (using TOMB_ROUTER)
     */
    address[] public wftmToLP0Route;
    address[] public wftmToLP1Route;

    /**
     * @dev Tomb variables
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

        address lpToken0 = IUniswapV2Pair(want).token0();
        address lpToken1 = IUniswapV2Pair(want).token1();

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
     *      1. Claims {TSHARE} from the {TSHARE_REWARDS_POOL}.
     *      2. Swaps {TSHARE} to {WFTM} using {SPOOKY_ROUTER}.
     *      3. Claims fees for the harvest caller and treasury.
     *      4. Swaps the {WFTM} token for {lpToken0} using {SPOOKY_ROUTER}.
     *      5. Swaps half of {lpToken0} to {lpToken1} using {TOMB_ROUTER}.
     *      6. Creates new LP tokens and deposits.
     */
    function _harvestCore() internal override {
        IMasterChef(MASTER_CHEF).harvest(poolId, address(this));
        _swapRewards();
        _chargeFees();
        _addLiquidity();
        _deposit();
    }

    /**
     * @dev Core harvest function. Swaps {LQDR} and {dualRewardToken} balances into {WFTM}.
     */
    function _swapRewards() internal {
        uint256 lqdrBal = IERC20Upgradeable(LQDR).balanceOf(address(this));
        address[] memory lqdrToWftmPath = new address[](2);
        lqdrToWftmPath[0] = LQDR;
        lqdrToWftmPath[1] = WFTM;
        _swap(lqdrBal, lqdrToWftmPath);
        uint256 deusBal = IERC20Upgradeable(DEUS).balanceOf(address(this));
        address[] memory deusToWftmPath = new address[](2);
        deusToWftmPath[0] = DEUS;
        deusToWftmPath[1] = WFTM;
        _swap(deusBal, deusToWftmPath);
    }

    /**
     * @dev Helper function to swap tokens given an {_amount}, swap {_path}, and {_router}.
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
        address lpToken0 = IUniswapV2Pair(want).token0();
        address lpToken1 = IUniswapV2Pair(want).token1();

        if (lpToken0 != WFTM) {
            address[] memory wftmToLP0Path = new address[](2);
            wftmToLP0Path[0] = WFTM;
            wftmToLP0Path[1] = lpToken0;
            _swap(wftmBalHalf, wftmToLP0Path);
        }
        if (lpToken1 != WFTM) {
            address[] memory wftmToLP1Path = new address[](2);
            wftmToLP1Path[0] = WFTM;
            wftmToLP1Path[1] = lpToken1;
            _swap(wftmBalHalf, wftmToLP1Path);
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

        // {DEUS} reward
        pendingReward = rewarder.pendingToken(poolId, address(this));
        totalRewards = pendingReward + IERC20Upgradeable(DEUS).balanceOf(address(this));
        if (totalRewards != 0) {
            address[] memory deusToWftmPath = new address[](2);
            deusToWftmPath[0] = DEUS;
            deusToWftmPath[1] = WFTM;
            profit += IUniswapV2Router02(SPIRIT_ROUTER).getAmountsOut(totalRewards, deusToWftmPath)[1];
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
     *      - deposit {want} into {TSHARE_REWARDS_POOL}
     *      - swap {TSHARE} using {SPOOKY_ROUTER}
     *      - swap {WFTM} using {SPOOKY_ROUTER}
     *      - swap {lpToken0} using {TOMB_ROUTER}
     *      - add liquidity using {lpToken0} and {lpToken1} in {TOMB_ROUTER}
     */
    function _giveAllowances() internal override {
        // want -> MASTER_CHEF
        uint256 wantAllowance = type(uint256).max - IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF);
        IERC20Upgradeable(want).safeIncreaseAllowance(MASTER_CHEF, wantAllowance);
        // LQDR -> SPIRIT_ROUTER
        uint256 lqdrAllowance = type(uint256).max - IERC20Upgradeable(LQDR).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(LQDR).safeIncreaseAllowance(SPIRIT_ROUTER, lqdrAllowance);
        // DEUS -> SPIRIT_ROUTER
        uint256 deusAllowance = type(uint256).max - IERC20Upgradeable(DEUS).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(DEUS).safeIncreaseAllowance(SPIRIT_ROUTER, deusAllowance);
        // WFTM -> SPIRIT_ROUTER
        uint256 wftmAllowance = type(uint256).max - IERC20Upgradeable(WFTM).allowance(address(this), SPIRIT_ROUTER);
        IERC20Upgradeable(WFTM).safeIncreaseAllowance(SPIRIT_ROUTER, wftmAllowance);

        address lpToken0 = IUniswapV2Pair(want).token0();
        address lpToken1 = IUniswapV2Pair(want).token1();
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
        IERC20Upgradeable(DEUS).safeDecreaseAllowance(
                SPIRIT_ROUTER,
                IERC20Upgradeable(DEUS).allowance(address(this), SPIRIT_ROUTER)
            );
        IERC20Upgradeable(WFTM).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20Upgradeable(WFTM).allowance(address(this), SPIRIT_ROUTER)
        );

        address lpToken0 = IUniswapV2Pair(want).token0();
        address lpToken1 = IUniswapV2Pair(want).token1();
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
        wftmToLP0Route = _route;
    }

    function setWftmToLP1Route(
        address[] memory _route
    ) external {
        _onlyStrategistOrOwner();
        wftmToLP1Route = _route;
    }
}
