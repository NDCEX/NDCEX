// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';
import './lib/SafeERC20.sol';
import './lib/SafeMath.sol';

contract FILPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    IERC20 public _lpt;

    uint256 public _totalReward;
    uint256 public _power; //GB

    uint256 public _totalToRelease;
    address public _borrower;
    IERC20 public _rewardToken;
    INDFILPool public _relationToken;
    uint256 public constant DURATION = 1 days;
    uint256 public constant RELEASE_DURATION = 180 days;
    address public _platform;
    address public _market;
    uint256 public _platformPct = 40;
    uint256 public _marketPct = 10;

    mapping(address => uint256) public releaseRewards;
    mapping(address => uint256) public releaseTimes;
    mapping(address => uint256) public durations;

    struct PoolInfo{
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 price; //GB
        uint256 totalPower;
        uint256 totalSupply;
        uint256 limit;
        uint256 startTime;
        uint256 earnDay;
        uint256 lockDay;
    }
    struct UserInfo{
        uint256 balance; //GB
        uint256 userRewardPerTokenPaid;
        uint256 reward;
        uint256 rewardsPaid;
        uint256 power; //GB
    }
    PoolInfo[] public poolList;
    mapping(uint256 => mapping(address => UserInfo)) public userInfoMap;

    event RewardAdded(uint256 totalReward, uint256 power);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReleasePaid(address indexed user, uint256 reward);

    constructor(
        address rewardToken,
        uint256 reward,
        uint256 power,
        address lpt,
        address relationToken,
        address borrower,
        address platform,
        address market
    ) public {
        _rewardToken = IERC20(rewardToken);
        _totalReward = reward;
        _power = power;
        _lpt = IERC20(lpt);
        _relationToken = INDFILPool(relationToken);
        _borrower = borrower;
        _platform = platform;
        _market = market;
    }

    modifier updateReward(uint256 poolId, address account) {
        poolList[poolId].rewardPerTokenStored = rewardPerToken(poolId);
        poolList[poolId].lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            userInfoMap[poolId][account].reward = earned(poolId, account);
            userInfoMap[poolId][account].userRewardPerTokenPaid = poolList[poolId].rewardPerTokenStored;
        }
        _;
    }
    
    modifier onlyBorrower() {
        require(_borrower == _msgSender(), "Caller is not the borrower");
        _;
    }

    //price /GB
    function createPool(uint256 price, uint256 limit, uint256 startTime, uint256 earnDay, uint256 lockDay) external onlyOwner{
        poolList.push(PoolInfo({
            lastUpdateTime: 0,
            rewardPerTokenStored: 0,
            price: price,
            totalPower: 0,
            totalSupply: 0,
            limit: limit,
            startTime: startTime,
            earnDay: earnDay,
            lockDay: lockDay
        }));
    }

    function changeReward(uint totalReward, uint power) external onlyOwner {
        for(uint i=0;i<poolList.length;i++){
            poolList[i].rewardPerTokenStored = rewardPerToken(i);
            poolList[i].lastUpdateTime = block.timestamp;
        }
        _totalReward = totalReward;
        _power = power;
        emit RewardAdded(totalReward, power);
    }

    function changeBorrower(address borrower) external onlyOwner{
        _borrower = borrower;
    }

    function changePlatformAndMarket(address platform, address market) external onlyOwner{
        _platform = platform;
        _market = market;
    }

    function changePlatformAndMarket(uint256 platformPct, uint256 marketPct) external onlyOwner{
        _platformPct = platformPct;
        _marketPct = marketPct;
    }

    //price /GB
    function changePrice(uint256 poolId, uint256 price) external onlyOwner{
        poolList[poolId].price = price;
    }

    function changeLimit(uint256 poolId, uint256 limit) external onlyOwner{
        poolList[poolId].limit = limit;
    }

    function changeStartTime(uint256 poolId, uint256 startTime) external onlyOwner{
        poolList[poolId].startTime = startTime;
    }

    function changeLockDay(uint256 poolId, uint256 earnDay, uint256 lockDay) external onlyOwner{
        poolList[poolId].earnDay = earnDay;
        poolList[poolId].lockDay = lockDay;
    }

    // reward /GB/s
    function getRewardRate() public view returns(uint256){
        if(_power == 0) return 0;
        return _totalReward.mul(1e18).div(_power).div(DURATION);
    }

    function rewardPerToken(uint256 poolId) public view returns (uint256) {
        if (poolList[poolId].totalSupply == 0 || block.timestamp < poolList[poolId].startTime) {
            return poolList[poolId].rewardPerTokenStored;
        }
        uint nowTime = poolList[poolId].earnDay.mul(DURATION).add(poolList[poolId].startTime).min(block.timestamp);
        (,uint time) = nowTime.trySub(poolList[poolId].lastUpdateTime);
        uint rewardRate = getRewardRate();
        return
        poolList[poolId].rewardPerTokenStored.add(
            time.mul(rewardRate)
        );
    }

    function earned(uint256 poolId, address account) public view returns (uint256) {
        return userInfoMap[poolId][account].power
            .mul(rewardPerToken(poolId).sub(userInfoMap[poolId][account].userRewardPerTokenPaid))
            .div(1e18)
            .add(userInfoMap[poolId][account].reward);
    }
    
    function received(uint256 poolId, address account) public view returns (uint256) {
        (uint256 release,) = released(account);
        return earned(poolId, account).mul(25).div(100).add(release);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 poolId, address referrer, uint256 power) public updateReward(poolId, msg.sender) {
        require(power > 0, 'Cannot stake 0');
        require(poolList[poolId].totalPower < poolList[poolId].limit, 'Overflow limit!');
        require(block.timestamp < poolList[poolId].startTime, 'Started!');
        power = poolList[poolId].limit.sub(poolList[poolId].totalPower).min(power);
        address account = msg.sender;
        _relationToken.bindRelationshipExternal(account, referrer);
        poolList[poolId].totalPower = poolList[poolId].totalPower.add(power);
        userInfoMap[poolId][account].power = userInfoMap[poolId][account].power.add(power);

        uint256 amount = poolList[poolId].price.mul(power).div(1e18);
        poolList[poolId].totalSupply = poolList[poolId].totalSupply.add(amount);
        userInfoMap[poolId][account].balance = userInfoMap[poolId][account].balance.add(amount);
        _lpt.safeTransferFrom(account, address(this), amount);
        emit Staked(account, amount);
    }

    function withdraw(uint256 poolId, uint256 amount) public updateReward(poolId, msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        require(block.timestamp > poolList[poolId].lockDay.mul(DURATION).add(poolList[poolId].startTime), 'Locked!');
        address account = msg.sender;
        uint256 balance = userInfoMap[poolId][account].balance;
        uint256 power = userInfoMap[poolId][account].power.mul(amount).div(balance);
        poolList[poolId].totalPower = poolList[poolId].totalPower.sub(power);
        userInfoMap[poolId][account].power = userInfoMap[poolId][account].power.sub(power);

        poolList[poolId].totalSupply = poolList[poolId].totalSupply.sub(amount);
        userInfoMap[poolId][account].balance = balance.sub(amount);
        _lpt.safeTransfer(account, amount);
        emit Withdrawn(account, amount);
    }

    function getReward(uint256 poolId) public updateReward(poolId, msg.sender) {
        address account = msg.sender;
        _getReleaseReward(account);
        uint256 reward = userInfoMap[poolId][account].reward;
        if (reward > 0) {
            userInfoMap[poolId][account].reward = 0;
            userInfoMap[poolId][account].rewardsPaid = userInfoMap[poolId][account].rewardsPaid.add(reward);
            emit RewardPaid(account, reward);

            uint256 toPlatform = reward.mul(_platformPct).div(100);
            uint256 toMarket = reward.mul(_marketPct).div(100);
            _rewardToken.safeTransfer(_platform, toPlatform);
            _rewardToken.safeTransfer(_market, toMarket);
            reward = reward.sub(toPlatform).sub(toMarket);

            uint256 toReleaseReward = reward.mul(75).div(100);
            reward = reward.sub(toReleaseReward);
            _rewardToken.safeTransfer(account, reward);
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
            _rewardToken.safeTransfer(account, reward);
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
    }
    
    function getPoolLength() public view returns(uint){
        return poolList.length;
    }

    function getList(uint start, uint length) public view 
    returns(uint256[] memory prices, uint256[] memory totalPowers, uint256[] memory totalSupplys, uint256[] memory limits, 
    uint256[] memory startTimes, uint256[] memory earnDays, uint256[] memory lockDays){
        uint256 minLength = (start+length).min(poolList.length);
        prices = new uint256[](minLength);
        totalPowers = new uint256[](minLength);
        totalSupplys = new uint256[](minLength);
        limits = new uint256[](minLength);
        startTimes = new uint256[](minLength);
        earnDays = new uint256[](minLength);
        lockDays = new uint256[](minLength);
        PoolInfo memory pool;
        for(uint i=start; i<minLength; i++){
            pool = poolList[i];
            prices[i-start] = pool.price;
            totalPowers[i-start] = pool.totalPower;
            totalSupplys[i-start] = pool.totalSupply;
            limits[i-start] = pool.limit;
            startTimes[i-start] = pool.startTime;
            earnDays[i-start] = pool.earnDay;
            lockDays[i-start] = pool.lockDay;
        }
        return (prices, totalPowers, totalSupplys, limits, startTimes, earnDays, lockDays);
    }

    function getListInfo(uint start, uint length, address account) public view 
    returns(uint256[] memory balances, uint256[] memory rewardsPaid, uint256[] memory rewards, uint256[] memory powers){
        uint256 minLength = (start+length).min(poolList.length);
        balances = new uint256[](minLength);
        rewardsPaid = new uint256[](minLength);
        rewards = new uint256[](minLength);
        powers = new uint256[](minLength);
        UserInfo memory user;
        for(uint i=start; i<minLength; i++){
            user = userInfoMap[i][account];
            balances[i-start] = user.balance;
            rewardsPaid[i-start] = user.rewardsPaid;
            powers[i-start] = user.power;
            if(user.balance > 0 || user.reward > 0)
                rewards[i-start] = earned(i, account);
        }
        return (balances, rewardsPaid, rewards, powers);
    }
}
