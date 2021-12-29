// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';
import './lib/SafeMath.sol';
import './lib/SafeERC20.sol';
interface IBoard {
    function allocateWithToken(uint256 amount) external;
    function allocate(uint256 amount) external;
}

contract NDFILPoolV2 is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public _lpt;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
    
    uint256 public _lastTotalReward;
    uint256 public _totalReward;
    uint256 public _power;
    
    uint256 public _totalToRelease;
    address public _borrower;
    IBoard public _board;
    IERC20 public _rewardToken;
    INDFILPool public _relationToken;
    uint256 public constant DURATION = 1 days;
    uint256 public constant RELEASE_DURATION = 180 days;
    uint256 public constant FREEZE_DURATION = 60 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => uint256) public releaseRewards;
    mapping(address => uint256) public releaseTimes;
    mapping(address => uint256) public durations;

    struct FreezeInfo{
        uint256 lockTime;
        uint256 freezeReward;
        uint256 needToken;
    }
    mapping(address => FreezeInfo) public freezes;

    event RewardAdded(uint256 reward, uint256 power);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReleasePaid(address indexed user, uint256 reward);
    event ChangeBorrower(address borrower);
    event ChangeBoard(address board);
    event RecoverWrongToken(address indexed tokenAddress, uint256 amount);

    constructor(
        address rewardToken,
        uint256 reward,
        uint256 power,
        address lpt,
        address relationToken,
        address borrower,
        address board
    ) public {
        require(rewardToken!=lpt,'');
        require(rewardToken != address(0), "Zero address!");
        require(lpt != address(0), "Zero address!");
        require(relationToken != address(0), "Zero address!");
        require(borrower != address(0), "Zero address!");
        require(board != address(0), "Zero address!");
        _rewardToken = IERC20(rewardToken);
        _totalReward = reward;
        _power = power;
        _lpt = IERC20(lpt);
        _relationToken = INDFILPool(relationToken);
        _borrower = borrower;
        _board = IBoard(board);
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

    function changeReward(uint reward, uint power) external onlyOwner updateReward(address(0)) {
        _lastTotalReward = _totalReward;
        _totalReward = reward;
        _power = power;
        emit RewardAdded(reward, power);
    }

    function changeBorrower(address borrower) external onlyOwner{
        require(borrower != address(0), "Zero address!");
        _borrower = borrower;
        emit ChangeBorrower(borrower);
    }

    function changeBoard(address board) external onlyOwner{
        require(board != address(0), "Zero address!");
        _board = IBoard(board);
        emit ChangeBoard(board);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0 || _power == 0) {
            return rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint totalReward = _totalReward;
        uint power = _power;
        uint rewardRate = totalSupply().mul(totalReward).mul(1e18).div(
            power.min(totalSupply().mul(10).div(7))
        ).div(DURATION);
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

        FreezeInfo memory freeze = freezes[account];
        if(freeze.needToken>0 && freeze.freezeReward>0){
            uint256 toReleaseReward;
            if(amount>=freeze.needToken){
                toReleaseReward = freeze.freezeReward;
                freezes[account].freezeReward = 0;
                freezes[account].needToken = 0;
            }else{
                toReleaseReward = amount.mul(freeze.freezeReward).div(freeze.needToken);
                freezes[account].freezeReward = freezes[account].freezeReward.sub(toReleaseReward);
                freezes[account].needToken = freezes[account].needToken.sub(amount);
            }
            addReleaseReward(account, toReleaseReward);
        }
        freezes[account].lockTime = weightedAvg(balanceOf(account), freezes[account].lockTime, amount, block.timestamp.add(FREEZE_DURATION));

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        _lpt.safeTransferFrom(account, address(this), amount);
        emit Staked(account, amount);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, 'Cannot withdraw 0');
        address account = msg.sender;
        uint256 toBoard;
        if(freezes[account].lockTime > FREEZE_DURATION.div(2).add(block.timestamp)){
            toBoard = amount.mul(10).div(100);
        }else if(freezes[account].lockTime > block.timestamp){
            toBoard = amount.mul(5).div(100);
        }
        if(toBoard>0){
            _lpt.safeTransfer(address(_board), toBoard);
            _board.allocate(toBoard);
            uint256 freezeReward = amount.mul(releaseRewards[account]).div(balanceOf(account));
            freezes[account].needToken = freezes[account].needToken.add(amount);
            freezes[account].freezeReward = freezes[account].freezeReward.add(freezeReward);
            releaseRewards[account] = releaseRewards[account].sub(freezeReward);
        }
        _totalSupply = _totalSupply.sub(amount);
        _balances[account] = _balances[account].sub(amount);
        _lpt.safeTransfer(account, amount.sub(toBoard));
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
