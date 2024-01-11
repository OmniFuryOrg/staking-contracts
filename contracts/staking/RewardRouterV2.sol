// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IVester.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../access/Governable.sol";

contract RewardRouterV2 is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public fury;
    address public esFury;
    address public bnFury;

    address public stakedFuryTracker;
    address public bonusFuryTracker;
    address public feeFuryTracker;

    address public furyVester;

    mapping (address => address) public pendingReceivers;

    event StakeFury(address account, address token, uint256 amount);
    event UnstakeFury(address account, address token, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _fury,
        address _esFury,
        address _bnFury,
        address _stakedFuryTracker,
        address _bonusFuryTracker,
        address _feeFuryTracker,
        address _furyVester
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        fury = _fury;
        esFury = _esFury;
        bnFury = _bnFury;

        stakedFuryTracker = _stakedFuryTracker;
        bonusFuryTracker = _bonusFuryTracker;
        feeFuryTracker = _feeFuryTracker;

        furyVester = _furyVester;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function batchStakeFuryForAccount(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyGov {
        address _fury = fury;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeFury(msg.sender, _accounts[i], _fury, _amounts[i]);
        }
    }

    function stakeFuryForAccount(address _account, uint256 _amount) external nonReentrant onlyGov {
        _stakeFury(msg.sender, _account, fury, _amount);
    }

    function stakeFury(uint256 _amount) external nonReentrant {
        _stakeFury(msg.sender, msg.sender, fury, _amount);
    }

    function stakeEsFury(uint256 _amount) external nonReentrant {
        _stakeFury(msg.sender, msg.sender, esFury, _amount);
    }

    function unstakeFury(uint256 _amount) external nonReentrant {
        _unstakeFury(msg.sender, fury, _amount, true);
    }

    function unstakeEsFury(uint256 _amount) external nonReentrant {
        _unstakeFury(msg.sender, esFury, _amount, true);
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeFuryTracker).claimForAccount(account, account);

        IRewardTracker(stakedFuryTracker).claimForAccount(account, account);
    }

    function claimEsFury() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedFuryTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeFuryTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(address _account) external nonReentrant onlyGov {
        _compound(_account);
    }

    function handleRewards(
        bool _shouldClaimFury,
        bool _shouldStakeFury,
        bool _shouldClaimEsFury,
        bool _shouldStakeEsFury,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        uint256 furyAmount = 0;
        if (_shouldClaimFury) {
            furyAmount = IVester(furyVester).claimForAccount(account, account);
        }

        if (_shouldStakeFury && furyAmount > 0) {
            _stakeFury(account, account, fury, furyAmount);
        }

        uint256 esFuryAmount = 0;
        if (_shouldClaimEsFury) {
            esFuryAmount = IRewardTracker(stakedFuryTracker).claimForAccount(account, account);
        }

        if (_shouldStakeEsFury && esFuryAmount > 0) {
            _stakeFury(account, account, esFury, esFuryAmount);
        }

        if (_shouldStakeMultiplierPoints) {
            uint256 bnFuryAmount = IRewardTracker(bonusFuryTracker).claimForAccount(account, account);
            if (bnFuryAmount > 0) {
                IRewardTracker(feeFuryTracker).stakeForAccount(account, account, bnFury, bnFuryAmount);
            }
        }

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth) {
                uint256 weth0 = IRewardTracker(feeFuryTracker).claimForAccount(account, address(this));
                uint256 wethAmount = weth0;
                IWETH(weth).withdraw(wethAmount);

                payable(account).sendValue(wethAmount);
            } else {
                IRewardTracker(feeFuryTracker).claimForAccount(account, account);
            }
        }
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        require(IERC20(furyVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");

        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        require(IERC20(furyVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");

        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        _compound(_sender);

        uint256 stakedFury = IRewardTracker(stakedFuryTracker).depositBalances(_sender, fury);
        if (stakedFury > 0) {
            _unstakeFury(_sender, fury, stakedFury, false);
            _stakeFury(_sender, receiver, fury, stakedFury);
        }

        uint256 stakedEsFury = IRewardTracker(stakedFuryTracker).depositBalances(_sender, esFury);
        if (stakedEsFury > 0) {
            _unstakeFury(_sender, esFury, stakedEsFury, false);
            _stakeFury(_sender, receiver, esFury, stakedEsFury);
        }

        uint256 stakedBnFury = IRewardTracker(feeFuryTracker).depositBalances(_sender, bnFury);
        if (stakedBnFury > 0) {
            IRewardTracker(feeFuryTracker).unstakeForAccount(_sender, bnFury, stakedBnFury, _sender);
            IRewardTracker(feeFuryTracker).stakeForAccount(_sender, receiver, bnFury, stakedBnFury);
        }

        uint256 esFuryBalance = IERC20(esFury).balanceOf(_sender);
        if (esFuryBalance > 0) {
            IERC20(esFury).transferFrom(_sender, receiver, esFuryBalance);
        }

        IVester(furyVester).transferStakeValues(_sender, receiver);
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(stakedFuryTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedFuryTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedFuryTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedFuryTracker.cumulativeRewards > 0");

        require(IRewardTracker(bonusFuryTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: bonusFuryTracker.averageStakedAmounts > 0");
        require(IRewardTracker(bonusFuryTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: bonusFuryTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeFuryTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeFuryTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeFuryTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeFuryTracker.cumulativeRewards > 0");

        require(IVester(furyVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: furyVester.transferredAverageStakedAmounts > 0");
        require(IVester(furyVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: furyVester.transferredCumulativeRewards > 0");

        require(IERC20(furyVester).balanceOf(_receiver) == 0, "RewardRouter: furyVester.balance > 0");
    }

    function _compound(address _account) private {
        _compoundFury(_account);
    }

    function _compoundFury(address _account) private {
        uint256 esFuryAmount = IRewardTracker(stakedFuryTracker).claimForAccount(_account, _account);
        if (esFuryAmount > 0) {
            _stakeFury(_account, _account, esFury, esFuryAmount);
        }

        uint256 bnFuryAmount = IRewardTracker(bonusFuryTracker).claimForAccount(_account, _account);
        if (bnFuryAmount > 0) {
            IRewardTracker(feeFuryTracker).stakeForAccount(_account, _account, bnFury, bnFuryAmount);
        }
    }

    function _stakeFury(address _fundingAccount, address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedFuryTracker).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(bonusFuryTracker).stakeForAccount(_account, _account, stakedFuryTracker, _amount);
        IRewardTracker(feeFuryTracker).stakeForAccount(_account, _account, bonusFuryTracker, _amount);

        emit StakeFury(_account, _token, _amount);
    }

    function _unstakeFury(address _account, address _token, uint256 _amount, bool _shouldReduceBnFury) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedFuryTracker).stakedAmounts(_account);

        IRewardTracker(feeFuryTracker).unstakeForAccount(_account, bonusFuryTracker, _amount, _account);
        IRewardTracker(bonusFuryTracker).unstakeForAccount(_account, stakedFuryTracker, _amount, _account);
        IRewardTracker(stakedFuryTracker).unstakeForAccount(_account, _token, _amount, _account);

        if (_shouldReduceBnFury) {
            uint256 bnFuryAmount = IRewardTracker(bonusFuryTracker).claimForAccount(_account, _account);
            if (bnFuryAmount > 0) {
                IRewardTracker(feeFuryTracker).stakeForAccount(_account, _account, bnFury, bnFuryAmount);
            }

            uint256 stakedBnFury = IRewardTracker(feeFuryTracker).depositBalances(_account, bnFury);
            if (stakedBnFury > 0) {
                uint256 reductionAmount = stakedBnFury.mul(_amount).div(balance);
                IRewardTracker(feeFuryTracker).unstakeForAccount(_account, bnFury, reductionAmount, _account);
                IMintable(bnFury).burn(_account, reductionAmount);
            }
        }

        emit UnstakeFury(_account, _token, _amount);
    }
}
