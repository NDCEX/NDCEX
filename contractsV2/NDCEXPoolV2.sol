// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';
import './lib/LPTokenWrapper.sol';

contract NDCEXPoolV2 is LPTokenWrapper, Ownable {

    uint public _pct;
    uint256 public _lockDay;
    uint256 public _totalReward;

    uint256 public _totalToRelease;
    address public _borrower;
    IERC20 public _rewardToken;
    INDFILPool public _relationToken;
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
    event ChangeBorrower(address borrower);
    event RecoverWrongToken(address indexed tokenAddress, uint256 amount);

    constructor(
        address rewardToken,
        uint256 reward,
        address lpt,
        address token,
        uint pct,
        uint lockDay,
        address borrower
    ) public {
        require(rewardToken!=lpt,'');
        require(rewardToken != address(0), "Zero address!");
        require(lpt != address(0), "Zero address!");
        require(token != address(0), "Zero address!");
        _rewardToken = IERC20(rewardToken);
        _totalReward = reward;
        _lpt = IERC20(lpt);
        _relationToken = INDFILPool(token);
        _pct = pct;
        _lockDay = lockDay;
        _borrower = borrower;
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
    
    modifier onlyBorrower() {
        require(_borrower == _msgSender(), "Caller is not the borrower");
        _;
    }

    function changeReward(uint reward) external onlyOwner updateReward(address(0)) {
        _totalReward = reward;
        emit RewardAdded(reward);
    }

    function changeBorrower(address borrower) external onlyOwner{
        _borrower = borrower;
        emit ChangeBorrower(borrower);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint totalReward = _totalReward;
        uint rewardRate = totalReward.mul(_pct).mul(1e18).div(100).div(DURATION);
        return
        rewardPerTokenStored.add(
            nowTime
            .sub(lastUpdateTime)
            .mul(rewardRate)
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
    
    function received(address account) public view returns (uint256) {
        (uint256 release,) = released(account);
        return earned(account).mul(25).div(100).add(release);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(address referrer, uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, 'Cannot stake 0');
        address account = msg.sender;
        _relationToken.bindRelationshipExternal(account, referrer);
        uint balance = balanceOf(account);
        uint lockTime = lockTimes[account];
        uint nowTime = block.timestamp;
        lockTimes[account] = weightedAvg(balance, lockTime, amount, nowTime.add(_lockDay.mul(DURATION)));
        super._stake(amount);
        emit Staked(account, amount);
    }

    function withdraw(uint256 amount) public override updateReward(msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        address account = msg.sender;
        require(block.timestamp > lockTimes[account], 'Locked');
        super.withdraw(amount);
        emit Withdrawn(account, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    function getReward() public updateReward(msg.sender) {
        address account = msg.sender;
        _getReleaseReward(account);
        uint256 reward = earned(account);
        if (reward > 0) {
            rewards[account] = 0;
            emit RewardPaid(account, reward);
            uint256 toReleaseReward = reward.mul(75).div(100);
            reward = reward.sub(toReleaseReward);
            _rewardToken.safeTransfer(account, reward.mul(80).div(100));
            addReleaseReward(account, toReleaseReward);
        }
    }
    
    function addReleaseReward(address account, uint256 toReleaseReward) private{
        uint nowTime = block.timestamp;
        uint toReleaseTime = nowTime.add(RELEASE_DURATION);
        uint lastToReleaseTime = releaseTimes[account];
        uint lastToReleaseReward = releaseRewards[account];
        _totalToRelease = _totalToRelease.add(toReleaseReward);
        releaseRewards[account] = lastToReleaseReward.add(toReleaseReward);
        releaseTimes[account] = weightedAvg(lastToReleaseReward, lastToReleaseTime, toReleaseReward, toReleaseTime);
        durations[account] = releaseTimes[account].sub(nowTime);
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
        uint duration = durations[account];
        if(releaseReward==0 || duration==0) return (0, 0);
        uint nowTime = block.timestamp;
        (, uint time) = releaseTimes[account].trySub(nowTime);
        return (releaseRewards[account].mul(duration.sub(time)).div(duration), time);
    }

    function getReleaseReward() public {
        _getReleaseReward(msg.sender);
    }
    
    function _getReleaseReward(address account) private {
        (uint256 reward, uint256 time) = released(account);
        if(reward>0){
            _totalToRelease = _totalToRelease.sub(reward);
            releaseRewards[account] = releaseRewards[account].sub(reward);
            durations[account] = time;
            emit ReleasePaid(account, reward);
            _rewardToken.safeTransfer(account, reward.mul(80).div(100));
        }
    }
    
    function getBorrowable(address account) external view returns(uint256){
        (uint256 reward, ) = released(account);
        return releaseRewards[account].sub(reward);
    }
    
    function getTotalToRelease() external view returns(uint256){
        return _totalToRelease;
    }
    
    function borrow(address account, uint256 amount) external onlyBorrower returns(uint256) {
        _getReleaseReward(account);
        if(amount == 0){
            amount = releaseRewards[account];
        }else{
            amount = releaseRewards[account].min(amount);
        }
        _totalToRelease = _totalToRelease.sub(amount);
        releaseRewards[account] = releaseRewards[account].sub(amount);
        return amount;
    }
    
    function repay(address account, uint256 amount) external onlyBorrower {
        require(amount > 0, 'Invalid repayment amount!');
        addReleaseReward(account, amount);
    }
    
    function recoverWrongToken(address tokenAddress, uint256 amount) external onlyOwner{
        require(tokenAddress!=address(_lpt), "Cannot be stakedToken!");
        require(tokenAddress!=address(_rewardToken), "Cannot be rewardToken!");
        IERC20(tokenAddress).safeTransfer(address(msg.sender), amount);
        emit RecoverWrongToken(tokenAddress, amount);
    }
}
