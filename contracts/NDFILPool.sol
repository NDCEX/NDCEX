// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './lib/IERC20.sol';
import './lib/Ownable.sol';
import './lib/Operator.sol';
import './lib/LPTokenWrapper.sol';

contract NDFILPool is LPTokenWrapper, Ownable, Operator {

    IERC20 public _rewardToken;
    uint256 public _lastTotalReward;
    uint256 public _totalReward;
    uint256 public _power;
    uint256 public constant DURATION = 1 days;
    uint256 public constant RELEASE_DURATION = 180 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => uint256) public releaseRewards;
    mapping(address => uint256) public releaseTimes;
    mapping(address => uint256) public durations;

    mapping(address => bool) public isWhitelist;
    address[] public starPlan;
    mapping(address => bool) public isStarPlan;
    mapping(address => User) public userMap;
    struct User {
        bool active;
        address referrer;
        uint subNum;
        uint totalPledge;
        uint totalIncome;
        address[] subordinates;
    }

    event RewardAdded(uint256 reward, uint256 power);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReleasePaid(address indexed user, uint256 reward);

    constructor(
        address rewardToken,
        uint256 reward,
        uint256 power,
        address lpt
    ) public {
        require(rewardToken!=lpt,'');
        _rewardToken = IERC20(rewardToken);
        _totalReward = reward;
        _power = power;
        _lpt = IERC20(lpt);
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

    function changeReward(uint reward, uint power) external onlyOwner updateReward(address(0)) {
        _lastTotalReward = _totalReward;
        _totalReward = reward;
        _power = power;
        emit RewardAdded(reward, power);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint totalReward = _totalReward;
        uint power = _power;
        // 挖矿效率*增强系数=总奖励/总流通量*0.7/MIN(0.7,总质押量/总流通量)=总奖励/MIN(总流通量,总质押量*10/7)
        uint rewardRate = totalSupply().mul(totalReward).div(
            power.min(totalSupply().mul(10).div(7))
        ).div(DURATION);
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
        bindRelationship(msg.sender, referrer);
        super._stake(amount);
        emit Staked(msg.sender, amount);
        if(userMap[referrer].active) userMap[referrer].totalPledge = userMap[referrer].totalPledge.add(amount);
    }

    function withdraw(uint256 amount) public override updateReward(msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
        address referrer = userMap[msg.sender].referrer;
        if(userMap[referrer].active) userMap[referrer].totalPledge = userMap[referrer].totalPledge.sub(amount);
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
            uint256 income = reward.mul(80).div(100);
            _rewardToken.safeTransfer(msg.sender, income);
            address referrer = userMap[msg.sender].referrer;
            if(userMap[referrer].active){
                income = income.mul(10).div(100);
                _rewardToken.safeTransfer(referrer, income);
                userMap[referrer].totalIncome = userMap[referrer].totalIncome.add(income);
            }

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
            uint256 income = reward.mul(80).div(100);
            _rewardToken.safeTransfer(msg.sender, income);
            address referrer = userMap[msg.sender].referrer;
            if(userMap[referrer].active){
                income = income.mul(10).div(100);
                _rewardToken.safeTransfer(referrer, income);
                userMap[referrer].totalIncome = userMap[referrer].totalIncome.add(income);
            }
        }
    }

    function getSuboradinateInfo() public view returns(address[] memory subordinates, uint256[] memory values) {
        subordinates = userMap[msg.sender].subordinates;
        for(uint i = 0; i < subordinates.length; i++){
            values[i] = balanceOf(subordinates[i]);
        }
    }

    function setWhitelist(address[] calldata contracts) external onlyOperator {
        for(uint i = 0; i < contracts.length; i++) {
            isWhitelist[contracts[i]] = true;
        }
    }

    function getStarPlan() public view returns(address[] memory){
        return starPlan;
    }

    function setStarPlan(address[] calldata addresses) external onlyOperator {
        for(uint i = 0; i < addresses.length; i++) {
            if(isStarPlan[addresses[i]]) continue;
            isStarPlan[addresses[i]] = true;
            starPlan.push(addresses[i]);
        }
    }

    function removeStarPlan(uint[] calldata indexes) external onlyOperator {
        for(uint i = 0; i < indexes.length; i++) {
            uint index = indexes[i];
            if(index>=starPlan.length) continue;
            isStarPlan[starPlan[index]] = false;
            delete starPlan[index];
        }
    }

    function bindRelationshipExternal(address account, address referrer) public {
        require(isWhitelist[msg.sender], "Insufficient permissions");
        bindRelationship(account, referrer);
    }

    function bindRelationship(address account, address referrer) internal {
        if (userMap[account].active) return;
        if(userMap[referrer].active && isStarPlan[referrer]) {
            userMap[account].referrer = referrer;
            userMap[referrer].subordinates.push(account);
            userMap[referrer].subNum++;
        }
        userMap[account].active = true;
    }
}
