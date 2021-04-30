// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';
import './lib/LPTokenWrapper.sol';

contract LPPool is LPTokenWrapper, Ownable {

    IERC20 public _rewardToken;
    IToken public _relationToken;
    uint256 public _reward;
    uint256 public constant DURATION = 1 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        address rewardToken,
        uint reward,
        address lpt,
        address token
    ) public {
        require(rewardToken!=lpt,'');
        _rewardToken = IERC20(rewardToken);
        _reward = reward;
        _lpt = IERC20(lpt);
        _relationToken = IToken(token);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint rewardRate = _reward.div(DURATION);
        return
        rewardPerTokenStored.add(
            nowTime
            .sub(lastUpdateTime)
            .mul(rewardRate)
            .mul(1e18)
            .div(totalSupply())
        );
    }

    function earned(address account) public view returns (uint256) {
        return
        balanceOf(account)
        .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
        .div(1e18)
        .add(rewards[account]);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(address referrer, uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, 'Cannot stake 0');
        _relationToken.bindRelationshipExternal(msg.sender, referrer);
        super._stake(amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override updateReward(msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function changeReward(uint reward) external onlyOwner updateReward(address(0)) {
        _reward = reward;
        emit RewardAdded(reward);
    }
}
