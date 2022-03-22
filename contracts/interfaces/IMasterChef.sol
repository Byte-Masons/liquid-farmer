// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMasterChef {
    function deposit(
        uint256 poolId,
        uint256 _amount,
        address user
    ) external;

    function withdraw(
        uint256 poolId,
        uint256 _amount,
        address user
    ) external;

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid, address user) external;

    function harvest(uint256 pid, address user) external;

    function rewarder(uint256) external view returns (address);

    function pendingLqdr(uint256 pid, address user) external view returns (uint256);
}
