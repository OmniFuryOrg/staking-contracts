// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IRewardRouterV3 {
    function feeOlpTracker() external view returns (address);
    function stakedOlpTracker() external view returns (address);
}
