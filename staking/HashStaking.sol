// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Ownable.sol";
import "./TransferHelper.sol";
import "./SafeMath.sol";

contract HashStaking is Ownable {
    using SafeMath for uint256;

    uint constant public STAKING_TOKENS_LIMIT = 15000000 * 10**18;
    uint constant public PARTNER_TOKENS_LIMIT = 1500000 * 10**18;
    uint constant public BLOCKS_TOTAL = 10512000;
    uint constant public REWARD_PER_BLOCK = STAKING_TOKENS_LIMIT / BLOCKS_TOTAL;
    uint constant public MAX_APR = 100;
    uint constant public PARTNER_PERCENT = 10;
    string constant public AGREEMENT = "I confirm I am not a citizen, national, resident (tax or otherwise) or holder of a green card of the USA and have never been a citizen, national, resident (tax or otherwise) or holder of a green card of the USA in the past.";
    string constant AGREEMENT_LENGTH = "223";

    address public hashTokenAddress;
    uint public stakingTokensLeft = STAKING_TOKENS_LIMIT;
    uint public partnerTokensLeft = PARTNER_TOKENS_LIMIT;
    uint public currentStakedAmount = 0;
    uint public finalStakedAmount = 0;
    uint public endBlock;

    struct User {
        uint stakedAmount;
        uint lastRewardBlock;
        uint rewardCollected;
        uint partnerRewardCollected;
        address partner;
        bytes agreementSignature;
        uint16 referral;
    }
    mapping(address => User) public users;

    address[] public participants;

    event Stake(
        address indexed user,
        address indexed partner,
        uint16 indexed referral,
        uint addedAmount,
        uint currentAmount,
        uint reward,
        uint partnerReward
    );
    event Unstake(
        address indexed user,
        address indexed partner,
        uint16 indexed referral,
        uint withdrawnAmount,
        uint currentAmount,
        uint reward,
        uint partnerReward,
        bool emergency
    );
    event Collect(
        address indexed user,
        address indexed partner,
        uint16 indexed referral,
        uint currentAmount,
        uint reward,
        uint partnerReward,
        bool compound
    );

    constructor(address _hashTokenAddress) {
        hashTokenAddress = _hashTokenAddress;
        endBlock = block.number + BLOCKS_TOTAL;
    }

    function withdrawRemainingTokens() external onlyOwner {
        require(block.number > endBlock, "The staking is not finished yet");
        uint contractBalance = _getHashBalance(address(this));
        uint reservedBalance = 0;
        for (uint i = 0; i < participants.length; i++) {
            uint userReward = _calculateReward(users[participants[i]].stakedAmount, users[participants[i]].lastRewardBlock);
            reservedBalance = reservedBalance.add(users[participants[i]].stakedAmount).add(userReward);
            if (users[participants[i]].partner != address(0)) {
                reservedBalance = reservedBalance.add(userReward.mul(PARTNER_PERCENT).div(100));
            }
        }
        require(contractBalance > reservedBalance, "Nothing to withdraw");
        TransferHelper.safeTransfer(hashTokenAddress, msg.sender, contractBalance.sub(reservedBalance));
    }

    function stake(uint _amount, address _partner, uint16 _referral, bytes calldata _agreementSignature) external {
        require(block.number < endBlock, "The staking is finished");
        require(_amount > 0, "Incorrect amount");
        User storage user = users[msg.sender];
        if (user.agreementSignature.length == 0) {
            require (_verifySignature(_agreementSignature, msg.sender), "Incorrect agreement signature");
            user.agreementSignature = _agreementSignature;
            if (_partner != address(0)) {
                user.partner = _partner;
            }
            if (_referral > 0) {
                user.referral = _referral;
            }
            participants.push(msg.sender);
        }
        (uint reward, uint partnerReward) = _collect(msg.sender, false);
        user.stakedAmount = user.stakedAmount.add(_amount);
        currentStakedAmount = currentStakedAmount.add(_amount);
        TransferHelper.safeTransferFrom(hashTokenAddress, msg.sender, address(this), _amount);
        emit Stake(msg.sender, user.partner, user.referral, _amount, user.stakedAmount, reward, partnerReward);
    }

    function unstake(uint _amount) external {
        _unstake(msg.sender, _amount, false);
    }

    function unstakeAll() external {
        _unstake(msg.sender, users[msg.sender].stakedAmount, false);
    }

    function collect() external {
        (uint reward, uint partnerReward) = _collect(msg.sender, false);
        require(reward > 0, "Nothing to collect");
        emit Collect(
            msg.sender,
            users[msg.sender].partner,
            users[msg.sender].referral,
            users[msg.sender].stakedAmount,
            reward,
            partnerReward,
            false
        );
    }

    function emergencyWithdraw() external {
        _unstake(msg.sender, users[msg.sender].stakedAmount, true);
    }

    function compound() external {
        (uint reward, uint partnerReward) = _collect(msg.sender, true);
        require(reward > 0, "Nothing to collect");
        emit Collect(
            msg.sender,
            users[msg.sender].partner,
            users[msg.sender].referral,
            users[msg.sender].stakedAmount,
            reward,
            partnerReward,
            true
        );
    }

    function getCurrentAPR() public view returns (uint apr) {
        if (block.number >= endBlock) {
            apr = 0;
        } else if (currentStakedAmount == 0) {
            apr = MAX_APR;
        } else {
            apr = stakingTokensLeft.mul(BLOCKS_TOTAL).mul(100).div(currentStakedAmount).div(endBlock.sub(block.number));
            if (apr > MAX_APR) {
                apr = MAX_APR;
            }
        }
    }

    function getCurrentStakedAmount(address _address) public view returns (uint) {
        return users[_address].stakedAmount;
    }

    function getPendingReward(address _address) public view returns (uint) {
        return _calculateReward(users[_address].stakedAmount, users[_address].lastRewardBlock);
    }

    function getPendingPartnerReward(address _address) external view returns (uint partnerReward) {
        partnerReward = 0;
        for (uint i = 0; i < participants.length; i++) {
            if (users[participants[i]].partner == _address) {
                uint userReward = _calculateReward(
                    users[participants[i]].stakedAmount,
                    users[participants[i]].lastRewardBlock
                );
                partnerReward = partnerReward.add(userReward.mul(PARTNER_PERCENT).div(100));
            }
        }
    }

    function countParticipants() external view returns (uint) {
        return participants.length;
    }

    function getCurrentInfo(address _address) external view returns (
        uint apr,
        uint totalStakedAmount,
        uint userStakedAmount,
        uint userPendingReward,
        bool isParticipant,
        uint blocksLeft,
        uint userRewardCollected,
        uint partnerRewardCollected,
        uint referrals,
        uint activeReferrals,
        uint referralsStakedAmount,
        uint referralsRewardCollected
    ) {
        apr = getCurrentAPR();
        totalStakedAmount = currentStakedAmount;
        userStakedAmount = getCurrentStakedAmount(_address);
        userPendingReward = getPendingReward(_address);
        isParticipant = users[_address].agreementSignature.length > 0;
        if (block.number < endBlock) {
            blocksLeft = endBlock - block.number;
        } else {
            blocksLeft = 0;
        }
        userRewardCollected = users[_address].rewardCollected;
        partnerRewardCollected = users[_address].partnerRewardCollected;
        referrals = 0;
        activeReferrals = 0;
        referralsStakedAmount = 0;
        referralsRewardCollected = 0;
        for (uint i = 0; i < participants.length; i++) {
            if (users[participants[i]].partner == _address) {
                referrals++;
                if (users[participants[i]].stakedAmount > 0) {
                    activeReferrals++;
                    referralsStakedAmount += users[participants[i]].stakedAmount;
                }
                referralsRewardCollected += users[participants[i]].rewardCollected;
            }
        }
    }

    function _unstake(address _address, uint _amount, bool _emergency) internal {
        require(_amount > 0, "Incorrect amount");
        if (block.number >= endBlock && finalStakedAmount == 0) {
            finalStakedAmount = currentStakedAmount;
        }
        (uint reward, uint partnerReward) = (0, 0);
        if (!_emergency) {
            (reward, partnerReward) = _collect(_address, false);
        }
        User storage user = users[_address];
        require(_amount <= user.stakedAmount, "Incorrect amount");
        user.stakedAmount = user.stakedAmount.sub(_amount);
        currentStakedAmount = currentStakedAmount.sub(_amount);
        TransferHelper.safeTransfer(hashTokenAddress, _address, _amount);
        emit Unstake(
            _address,
            user.partner,
            user.referral,
            _amount,
            user.stakedAmount,
            reward,
            partnerReward,
            _emergency
        );
    }

    function _collect(address _address, bool _compound) internal returns (uint reward, uint partnerReward) {
        User storage user = users[_address];
        reward = _calculateReward(user.stakedAmount, user.lastRewardBlock);
        partnerReward = 0;
        if (reward > 0) {
            if (_compound) {
                user.stakedAmount = user.stakedAmount.add(reward);
                currentStakedAmount = currentStakedAmount.add(reward);
            } else {
                TransferHelper.safeTransfer(hashTokenAddress, _address, reward);
            }
            stakingTokensLeft = stakingTokensLeft.sub(reward);
            user.rewardCollected = user.rewardCollected.add(reward);
            if (user.partner != address(0)) {
                partnerReward = reward.mul(PARTNER_PERCENT).div(100);
                if (partnerReward > 0) {
                    TransferHelper.safeTransfer(hashTokenAddress, user.partner, partnerReward);
                    partnerTokensLeft = stakingTokensLeft.sub(partnerReward);
                    users[user.partner].partnerRewardCollected = users[user.partner].partnerRewardCollected.add(partnerReward);
                }
            }
        }
        user.lastRewardBlock = block.number;
    }

    function _calculateReward(uint _stakedAmount, uint _lastRewardBlock) internal view returns (uint) {
        if (currentStakedAmount == 0) {
            return 0;
        }
        uint currentBlock = block.number;
        uint blocks = 0;
        if (currentBlock > endBlock) {
            currentBlock = endBlock;
        }
        if (currentBlock > _lastRewardBlock) {
            blocks = currentBlock.sub(_lastRewardBlock);
        }
        uint totalStakedAmount = finalStakedAmount > 0 ? finalStakedAmount : currentStakedAmount;
        uint maxReward = _stakedAmount.mul(MAX_APR).mul(blocks).div(BLOCKS_TOTAL).div(100);
        uint reward = REWARD_PER_BLOCK.mul(blocks).mul(_stakedAmount).div(totalStakedAmount);
        if (reward > maxReward) {
            reward = maxReward;
        }
        return reward;
    }

    function _getHashBalance(address _address) internal returns (uint) {
        (bool success, bytes memory data) = hashTokenAddress.call(
            abi.encodeWithSelector(bytes4(keccak256(bytes('balanceOf(address)'))), _address)
        );
        require(success, "Getting HASH balance failed");
        return abi.decode(data, (uint));
    }

    function _verifySignature(bytes memory _sign, address _signer) pure internal returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", AGREEMENT_LENGTH, AGREEMENT));
        address[] memory signList = _recoverAddresses(hash, _sign);
        return signList[0] == _signer;
    }

    function _recoverAddresses(bytes32 _hash, bytes memory _signatures) pure internal returns (address[] memory addresses) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint count = _countSignatures(_signatures);
        addresses = new address[](count);
        for (uint i = 0; i < count; i++) {
            (v, r, s) = _parseSignature(_signatures, i);
            addresses[i] = ecrecover(_hash, v, r, s);
        }
    }

    function _parseSignature(bytes memory _signatures, uint _pos) pure internal returns (uint8 v, bytes32 r, bytes32 s) {
        uint offset = _pos * 65;
        assembly {
            r := mload(add(_signatures, add(32, offset)))
            s := mload(add(_signatures, add(64, offset)))
            v := and(mload(add(_signatures, add(65, offset))), 0xff)
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28);
    }

    function _countSignatures(bytes memory _signatures) pure internal returns (uint) {
        return _signatures.length % 65 == 0 ? _signatures.length / 65 : 0;
    }
}