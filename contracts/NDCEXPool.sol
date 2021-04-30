// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';
import './lib/LPTokenWrapper.sol';

contract NDCEXPool is LPTokenWrapper, Ownable {

    uint public _pct;
    uint256 public _lockDay;
    uint256 public _totalReward;

    IERC20 public _rewardToken;
    IToken public _relationToken;
    uint256 public constant DURATION = 1 days;
    uint256 public constant RELEASE_DURATION = 180 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => uint256) public releaseRewards;
    mapping(address => uint256) public releaseTimes;
    mapping(address => uint256) public durations;
    mapping(address => uint256) public lockTimes;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReleasePaid(address indexed user, uint256 reward);

    constructor(
        address rewardToken,
        uint256 reward,
        address lpt,
        address token,
        uint pct,
        uint lockDay
    ) public {
        require(rewardToken!=lpt,'');
        _rewardToken = IERC20(rewardToken);
        _totalReward = reward;
        _lpt = IERC20(lpt);
        _relationToken = IToken(token);
        _pct = pct;
        _lockDay = lockDay;
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

    function changeReward(uint reward) external onlyOwner updateReward(address(0)) {
        _totalReward = reward;
        emit RewardAdded(reward);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint totalReward = _totalReward;
        // 挖矿效率*总流通量*pct=总奖励*pct
        uint rewardRate = totalReward.mul(_pct).div(100).div(DURATION);
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
        uint balance = balanceOf(msg.sender);
        uint lockTime = lockTimes[msg.sender];
        uint nowTime = block.timestamp;
        lockTimes[msg.sender] = weightedAvg(balance, lockTime, amount, nowTime.add(_lockDay.mul(DURATION)));
        super._stake(amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override updateReward(msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        require(block.timestamp > lockTimes[msg.sender], 'Locked');
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
            emit RewardPaid(msg.sender, reward);
            uint256 toReleaseReward = reward.mul(75).div(100);
            reward = reward.sub(toReleaseReward);
            _rewardToken.safeTransfer(msg.sender, reward.mul(80).div(100));
            uint nowTime = block.timestamp;
            uint toReleaseTime = nowTime.add(RELEASE_DURATION);
            uint lastToReleaseTime = releaseTimes[msg.sender];
            uint lastToReleaseReward = releaseRewards[msg.sender];
            releaseRewards[msg.sender] = lastToReleaseReward.add(toReleaseReward);
            releaseTimes[msg.sender] = weightedAvg(lastToReleaseReward, lastToReleaseTime, toReleaseReward, toReleaseTime);
            durations[msg.sender] = releaseTimes[msg.sender].sub(nowTime);
        }
    }

    function weightedAvg(uint amount1, uint releaseTime1, uint amount2, uint releaseTime2) public view returns (uint avg){
        uint nowTime = block.timestamp;
        (, uint time1) = releaseTime1.trySub(nowTime);
        (, uint time2) = releaseTime2.trySub(nowTime);
        avg = time1.mul(amount1)
        .add(time2.mul(amount2))
        .div(amount1.add(amount2))
        .add(nowTime);
    }

    function released(address account) public view returns (uint256, uint256) {
        uint releaseReward = releaseRewards[account];
        uint duration = durations[msg.sender];
        if(releaseReward==0 || duration==0) return (0, 0);
        uint nowTime = block.timestamp;
        (, uint time) = releaseTimes[account].trySub(nowTime);
        return (releaseRewards[account].mul(duration.sub(time)).div(duration), time);
    }

    function getReleaseReward() public {
        (uint256 reward, uint256 time) = released(msg.sender);
        if(reward>0){
            releaseRewards[msg.sender] = releaseRewards[msg.sender].sub(reward);
            durations[msg.sender] = time;
            emit ReleasePaid(msg.sender, reward);
            _rewardToken.safeTransfer(msg.sender, reward.mul(80).div(100));
        }
    }
}
