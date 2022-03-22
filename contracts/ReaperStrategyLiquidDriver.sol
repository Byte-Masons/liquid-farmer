// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./abstract/ReaperBaseStrategyv1_1.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "hardhat/console.sol";

/**
 * @dev Deposit TOMB-MAI LP in TShareRewardsPool. Harvest TSHARE rewards and recompound.
 */
contract ReaperStrategyLiquidDriver is ReaperBaseStrategyv1_1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // 3rd-party contract addresses
    address public router;
    address public dualRewardRouter;
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
    address public dualRewardToken;
    address public lpToken0;
    address public lpToken1;
    address public want;

    /**
     * @dev Paths used to swap tokens:
     * {tshareToWftmPath} - to swap {TSHARE} to {WFTM} (using SPOOKY_ROUTER)
     * {wftmToTombPath} - to swap {WFTM} to {lpToken0} (using SPOOKY_ROUTER)
     * {tombToMaiPath} - to swap half of {lpToken0} to {lpToken1} (using TOMB_ROUTER)
     */
    address[] public dualRewardRoute;

    /**
     * @dev Tomb variables
     * {poolId} - ID of pool in which to deposit LP tokens
     */
    uint256 public poolId;
    bool public useDualRewards;

    /**
     * @dev Initializes the strategy. Sets parameters and saves routes.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address _want,
        uint256 _poolId,
        address _router
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        want = _want;
        poolId = _poolId;
        router = _router;
        useDualRewards = false;

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

        // uint256 wftmBal = IERC20Upgradeable(WFTM).balanceOf(address(this));
        // _swap(wftmBal, wftmToTombPath, SPOOKY_ROUTER);
        // uint256 tombHalf = IERC20Upgradeable(lpToken0).balanceOf(address(this)) / 2;
        // _swap(tombHalf, tombToMaiPath, TOMB_ROUTER);

        // _addLiquidity();
        // deposit();
    }

    /**
     * @dev Core harvest function. Swaps {LQDR} and {dualRewardToken} balances into {WFTM}.
     */
    function _swapRewards() internal {
        uint256 lqdrBal = IERC20Upgradeable(LQDR).balanceOf(address(this));
        address[] memory lqdrToWftmPath = new address[](2);
        lqdrToWftmPath[0] = LQDR;
        lqdrToWftmPath[1] = WFTM;
        _swap(lqdrBal, lqdrToWftmPath, router);
        if (useDualRewards) {
            uint256 dualRewardTokenBal = IERC20Upgradeable(dualRewardToken).balanceOf(address(this));
            _swap(dualRewardTokenBal, dualRewardRoute, dualRewardRouter);
        }
    }

    /**
     * @dev Helper function to swap tokens given an {_amount}, swap {_path}, and {_router}.
     */
    function _swap(
        uint256 _amount,
        address[] memory _path,
        address _router
    ) internal {
        if (_path.length < 2 || _amount == 0) {
            return;
        }

        IUniswapV2Router02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
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
        // uint256 lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
        // uint256 lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));

        // if (lp0Bal != 0 && lp1Bal != 0) {
        //     IUniswapV2Router02(TOMB_ROUTER).addLiquidity(
        //         lpToken0,
        //         lpToken1,
        //         lp0Bal,
        //         lp1Bal,
        //         0,
        //         0,
        //         address(this),
        //         block.timestamp
        //     );
        // }
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
        // uint256 pendingReward = IMasterChef(TSHARE_REWARDS_POOL).pendingShare(poolId, address(this));
        // uint256 totalRewards = pendingReward + IERC20Upgradeable(TSHARE).balanceOf(address(this));

        // if (totalRewards != 0) {
        //     profit += IUniswapV2Router02(SPOOKY_ROUTER).getAmountsOut(totalRewards, tshareToWftmPath)[1];
        // }

        // profit += IERC20Upgradeable(WFTM).balanceOf(address(this));

        // uint256 wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        // callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        // profit -= wftmFee;
    }

    /**
     * @dev Function to retire the strategy. Claims all rewards and withdraws
     *      all principal from external contracts, and sends everything back to
     *      the vault. Can only be called by strategist or owner.
     *
     * Note: this is not an emergency withdraw function. For that, see panic().
     */
    function _retireStrat() internal override {
        // IMasterChef(TSHARE_REWARDS_POOL).deposit(poolId, 0); // deposit 0 to claim rewards

        // uint256 tshareBal = IERC20Upgradeable(TSHARE).balanceOf(address(this));
        // _swap(tshareBal, tshareToWftmPath, SPOOKY_ROUTER);

        // uint256 wftmBal = IERC20Upgradeable(WFTM).balanceOf(address(this));
        // _swap(wftmBal, wftmToTombPath, SPOOKY_ROUTER);
        // uint256 tombHalf = IERC20Upgradeable(lpToken0).balanceOf(address(this)) / 2;
        // _swap(tombHalf, tombToMaiPath, TOMB_ROUTER);

        // _addLiquidity();

        // (uint256 poolBal, ) = IMasterChef(TSHARE_REWARDS_POOL).userInfo(poolId, address(this));
        // IMasterChef(TSHARE_REWARDS_POOL).withdraw(poolId, poolBal);

        // uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        // IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * Withdraws all funds leaving rewards behind.
     */
    function _reclaimWant() internal override {
        // IMasterChef(TSHARE_REWARDS_POOL).emergencyWithdraw(poolId);
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
        // LQDR -> router
        uint256 lqdrAllowance = type(uint256).max - IERC20Upgradeable(LQDR).allowance(address(this), router);
        IERC20Upgradeable(LQDR).safeIncreaseAllowance(router, lqdrAllowance);
        if (useDualRewards) {
            // dualRewardToken -> router
            uint256 dualRewardTokenAllowance = type(uint256).max - IERC20Upgradeable(dualRewardToken).allowance(address(this), dualRewardRouter);
            IERC20Upgradeable(dualRewardToken).safeIncreaseAllowance(dualRewardRouter, dualRewardTokenAllowance);
        }
        // // WFTM -> SPOOKY_ROUTER
        // uint256 wftmAllowance = type(uint256).max - IERC20Upgradeable(WFTM).allowance(address(this), SPOOKY_ROUTER);
        // IERC20Upgradeable(WFTM).safeIncreaseAllowance(SPOOKY_ROUTER, wftmAllowance);
        // // depositToken -> swapPool
        // uint256 depositAllowance = type(uint256).max - IERC20Upgradeable(depositToken).allowance(address(this), swapPool);
        // IERC20Upgradeable(depositToken).safeIncreaseAllowance(swapPool, depositAllowance);
    }

    /**
     * @dev Removes all the allowances that were given above.
     */
    function _removeAllowances() internal override {
        IERC20Upgradeable(want).safeDecreaseAllowance(
            MASTER_CHEF,
            IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF)
        );
        // IERC20Upgradeable(TSHARE).safeApprove(SPOOKY_ROUTER, 0);
        // IERC20Upgradeable(WFTM).safeApprove(SPOOKY_ROUTER, 0);
        // IERC20Upgradeable(lpToken0).safeApprove(TOMB_ROUTER, 0);
        // IERC20Upgradeable(lpToken1).safeApprove(TOMB_ROUTER, 0);
    }

    function dualRewardSetUp(
        address _token,
        address _router,
        address[] memory _toWftmRoute
    ) external {
        _onlyStrategistOrOwner();
        dualRewardToken = _token;
        dualRewardRouter = _router;
        dualRewardRoute = _toWftmRoute;
        _giveAllowances();
    }

    function setUseDualRewards(bool _useDualRewards) external {
        _onlyStrategistOrOwner();
        useDualRewards = _useDualRewards;
    }
}
