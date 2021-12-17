// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './lib/SafeMath.sol';
import './lib/IERC20.sol';
import './lib/INDFILPool.sol';
import './lib/Ownable.sol';

interface IPool {
    function getTotalToRelease() external view returns(uint256);
    function borrow(address account, uint256 amount) external returns(uint256);
    function repay(address account, uint256 amount) external;
    function getBorrowable(address account) external view returns(uint256);
}
interface IBoard {
    function allocateWithToken(uint256 amount) external;
    function allocate(uint256 amount) external;
}

contract Borrow is Ownable {
    using SafeMath for uint256;

    IERC20 public _rewardToken;
    INDFILPool public _relationToken;
    IERC20 public _token;
    IBoard public _board;
    uint256 public constant DURATION = 1 days;
    uint256 public borrowRateOfRelease = 69 * 1e14;
    uint256 public baseRate = 54794520547200; //1902587519*28800;
    uint256 public utilizationFactor = 913242009110400; //31709791983*28800;
    uint256 public utilizationFactor2 = 2739726027388800; //95129375951*28800;
    uint256 public turnPoint = 90 * 1e16;
    uint256 private constant MAX = ~uint256(0);
    uint256 public reserveFactor = 20;
    uint256 public borrowIndex = 1e18;
    uint256 public borrowIndex1 = 1e18;
    
    struct UserDepositInfo{
        uint256 balance;
        uint256 userRewardPerTokenPaid;
        uint256 rewards;
        uint256 rewardsPaid;
        uint256 borrowed;
    }
    struct DepositPool{
        uint256 totalSupply;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    struct UserBorrowInfo{
        uint256 balance;
        uint256 principal;
        uint256 rewardsPaid;
        bool isActive;
        uint256 interestIndex;
    }
    struct BorrowPool{
        uint256 totalSupply;
        uint256 lastUpdateTime;
        uint256 totalReserves;
    }
    struct BorrowListInfo{
        address pool;
        uint256 totalSupply;
        bool isValid;
        uint256 index;
        uint256 borrowFactor;
        uint256 clearFactor;
    }
    struct ClearInfo{
        address account;
        address pool;
        uint256 balance;
        uint256 interest;
        uint256 time;
    }
    ClearInfo[] public clearList;
    mapping(address => ClearInfo[]) public clearListMap;
    uint256 public totalClearReleased;
    uint256 public totalClearDeposit;
    uint256 public totalClearBorrowed;
    uint256 public clearIndex;
    uint256 public clearNumber = 1;
    
    DepositPool public depositPool;
    mapping(address => UserDepositInfo) public userDepositMap;
    
    BorrowPool public borrowPool;
    BorrowListInfo[] public poolList;
    mapping(uint256 => mapping(address => UserBorrowInfo)) public userBorrowMap;
    mapping(uint256 => address[]) public userListMap;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Clear(address user, address pool, uint256 amount);

    constructor(
        address rewardToken,
        address token,
        address relationToken,
        address board
    ) public {
        _rewardToken = IERC20(rewardToken);
        _token = IERC20(token);
        _relationToken = INDFILPool(relationToken);
        _board = IBoard(board);
        poolList.push(BorrowListInfo({
            pool: address(this),
            totalSupply: 0,
            isValid: true,
            index: 0,
            borrowFactor: 60,
            clearFactor: 100
        }));
    }

    modifier updateReward(address account) {
        depositPool.rewardPerTokenStored = rewardPerToken();
        depositPool.lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            userDepositMap[account].rewards = earned(account);
            userDepositMap[account].userRewardPerTokenPaid = depositPool.rewardPerTokenStored;
        }
        _;
    }
    
    modifier updateInterest(uint poolId, address account){
        uint256 interestPerTokenAdded;
        uint256 interestPerTokenAdded1;
        (interestPerTokenAdded, borrowIndex) = getBorrowIndex(0);
        (interestPerTokenAdded1, borrowIndex1) = getBorrowIndex(1);
        borrowPool.lastUpdateTime = block.timestamp;

        uint256 interest = interestPerTokenAdded.mul(poolList[0].totalSupply).div(1e18);
        uint256 interest1 = interestPerTokenAdded1.mul(
            borrowPool.totalSupply.sub(poolList[0].totalSupply)
        ).div(1e18);
        
        borrowPool.totalSupply = interest.add(interest1).add(borrowPool.totalSupply);
        borrowPool.totalReserves = interest.add(interest1).mul(reserveFactor).div(100).add(borrowPool.totalReserves);
        poolList[0].totalSupply = interest.add(poolList[0].totalSupply);

        if (account != address(0)) {
            userBorrowMap[poolId][account].principal = getPrincipal(poolId, account);
            userBorrowMap[poolId][account].interestIndex = poolId == 0 ? borrowIndex : borrowIndex1;
        }
        _;
    }

    function getBorrowIndex(uint256 poolId) public view returns(uint256, uint256){
        (, uint256 borrowRate1, uint256 borrowRate2) = getBorrowRate();
        uint256 _borrowRate;
        uint256 _borrowIndex;
        if(poolId == 0){
            _borrowRate = borrowRate2;
            _borrowIndex = borrowIndex;
            if(poolList[0].totalSupply==0) return (0, _borrowIndex);
        }else{
            _borrowRate = borrowRate1;
            _borrowIndex = borrowIndex1;
            if(borrowPool.totalSupply.sub(poolList[0].totalSupply)==0) return (0, _borrowIndex);
        }
        uint256 interestPerTokenAdded = block.timestamp.sub(borrowPool.lastUpdateTime).mul(_borrowRate).div(DURATION);
        uint256 borrowIndexNew = interestPerTokenAdded.mul(_borrowIndex).div(1e18).add(_borrowIndex);
        return (interestPerTokenAdded, borrowIndexNew);
    }
    
    function createPool(address pool, uint256 borrowFactor, uint256 clearFactor) public onlyOwner {
        poolList.push(BorrowListInfo({
            pool: pool,
            totalSupply: 0,
            isValid: true,
            index: 0,
            borrowFactor: borrowFactor,
            clearFactor: clearFactor
        }));
    }

    function changePoolValid(uint poolId, bool isValid) external onlyOwner updateInterest(0, address(0)) updateReward(address(0)) {
        poolList[poolId].isValid = isValid;
    }

    function changePoolAddress(uint poolId, address pool) external onlyOwner updateInterest(0, address(0)) updateReward(address(0)) {
        poolList[poolId].pool = pool;
    }

    function changeClearNumber(uint _clearNumber) external onlyOwner {
        clearNumber = _clearNumber;
    }

    function changeReward(uint _borrowRateOfRelease, uint _baseRate, uint _utilizationFactor, uint _utilizationFactor2, uint _turnPoint) external onlyOwner updateInterest(0, address(0)) updateReward(address(0)) {
        borrowRateOfRelease = _borrowRateOfRelease;
        baseRate = _baseRate;
        utilizationFactor = _utilizationFactor;
        utilizationFactor2 = _utilizationFactor2;
        turnPoint = _turnPoint;
    }

    function changeBoard(address board) external onlyOwner{
        _board = IBoard(board);
    }

    function update(address account) public updateReward(account) {}
    
    // Scale 1e18
    function utilizationRate() public view returns (uint){
        if(borrowPool.totalSupply==0) return 0;
        return borrowPool.totalSupply.mul(1e18).div(
            _token.balanceOf(address(this)).add(borrowPool.totalSupply).sub(borrowPool.totalReserves)
        );
    }
    
    // Scale 1e18
    function getBorrowRate() public view returns (uint, uint, uint){
        uint256 borrowRate1 = borrowRateOfRelease;
        uint256 ur = utilizationRate();
        (bool flag, uint rate) = ur.trySub(turnPoint);
        if(flag) ur = turnPoint;
        uint256 borrowRate2 = baseRate.add(
            ur.mul(utilizationFactor).div(1e18)
        ).add(
            rate.mul(utilizationFactor2).div(1e18)
        );
        uint256 borrowRate;
        if(borrowPool.totalSupply==0){
            borrowRate = borrowRate1.add(borrowRate2).div(2);
        }else{
            borrowRate = borrowPool.totalSupply.sub(poolList[0].totalSupply).mul(borrowRate1).add(
                poolList[0].totalSupply.mul(borrowRate2)
            ).div(borrowPool.totalSupply);
        }
        return (borrowRate, borrowRate1, borrowRate2);
    }
    
    // Scale 1e18
    function getSupplyRate() public view returns (uint){
        (uint256 borrowRate,,) = getBorrowRate();
        return utilizationRate().mul(borrowRate).mul(uint256(100).sub(reserveFactor)).div(100).div(1e18);
    }
    
    function getDailyRewardAndInterest() public view returns (uint, uint){
        (uint256 borrowRate,,) = getBorrowRate();
        uint256 reward = getSupplyRate().mul(depositPool.totalSupply).div(1e18);
        uint256 interest = borrowRate.mul(borrowPool.totalSupply).div(1e18);
        return (reward, interest);
    }
    
    function totalSupply() public view returns (uint256) {
        return depositPool.totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        return userDepositMap[account].balance;
    }
    
    function withdrawalbe(address account) public view returns (uint256) {
        return userDepositMap[account].balance.sub(userDepositMap[account].borrowed);
    }

    function getPrincipal(uint256 poolId, address account) public view returns(uint256){
        uint256 interestIndex = userBorrowMap[poolId][account].interestIndex;
        if(interestIndex==0) interestIndex = 1e18;
        uint256 principal = userBorrowMap[poolId][account].principal;
        if(principal==0) principal = userBorrowMap[poolId][account].balance;
        (,uint256 borrowIndexNew) = getBorrowIndex(poolId);
        return principal.mul(borrowIndexNew).div(interestIndex);
    }
    
    function owed(uint poolId, address account) public view returns(uint256 interest){
        (,interest) = getPrincipal(poolId, account).trySub(userBorrowMap[poolId][account].balance);
    }
    
    function borrow(address referrer, uint256 amount, uint256 poolId) public updateInterest(poolId, msg.sender) updateReward(address(0)){
        clear(0);
        address account = msg.sender;
        require(poolList[poolId].isValid, 'Pool is invalid!');
        _relationToken.bindRelationshipExternal(account, referrer);
        if(poolId==0){
            uint256 max = userDepositMap[account].balance.sub(userDepositMap[account].borrowed);
            amount = amount == 0 ? max : amount.min(max);
            userDepositMap[account].borrowed = userDepositMap[account].borrowed.add(amount);
        }else{
            IPool pool = IPool(poolList[poolId].pool);
            uint256 max = pool.getBorrowable(account);
            amount = amount == 0 ? max : amount.min(max);
            pool.borrow(account, amount);
        }
        amount = amount.mul(poolList[poolId].borrowFactor).mul(poolList[poolId].clearFactor).div(10000);
        borrowPool.totalSupply = borrowPool.totalSupply.add(amount);
        poolList[poolId].totalSupply = poolList[poolId].totalSupply.add(amount);
        userBorrowMap[poolId][account].balance = userBorrowMap[poolId][account].balance.add(amount);
        userBorrowMap[poolId][account].principal = userBorrowMap[poolId][account].principal.add(amount);
        _token.transfer(account, amount);
        emit Borrowed(account, amount);
        if(!userBorrowMap[poolId][account].isActive){
            userListMap[poolId].push(account);
            userBorrowMap[poolId][account].isActive = true;
        }
    }
    
    function repay(uint256 amount, uint256 poolId) public updateInterest(poolId, msg.sender){
        clear(0);
        address account = msg.sender;
        uint256 interest = userBorrowMap[poolId][account].principal.sub(userBorrowMap[poolId][account].balance);
        uint256 max = userBorrowMap[poolId][account].principal;
        amount = amount == 0 ? max : amount.min(max);
        if(amount == 0) return;
        _token.transferFrom(account, address(this), amount);
        emit Repaid(account, amount);
        (bool payOff, uint256 principal) = amount.trySub(interest);
        if(payOff){
            update(address(0));
            if(poolId!=0) poolList[poolId].totalSupply = poolList[poolId].totalSupply.sub(principal);
            userBorrowMap[poolId][account].balance = userBorrowMap[poolId][account].balance.sub(principal);
            principal = principal.mul(10000).div(poolList[poolId].borrowFactor).div(poolList[poolId].clearFactor);
            if(poolId==0){
                if(userBorrowMap[poolId][account].balance==0) userDepositMap[account].borrowed = 0;
                else userDepositMap[account].borrowed = userDepositMap[account].borrowed.sub(principal);
            }else{
                IPool pool = IPool(poolList[poolId].pool);
                pool.repay(account, principal);
            }
        }
        if(poolId==0) (,poolList[poolId].totalSupply) = poolList[poolId].totalSupply.trySub(amount);
        (,userBorrowMap[poolId][account].principal) = userBorrowMap[poolId][account].principal.trySub(amount);
        (,borrowPool.totalSupply) = borrowPool.totalSupply.trySub(amount);
        userBorrowMap[poolId][account].rewardsPaid = userBorrowMap[poolId][account].rewardsPaid.add(amount.min(interest));
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return depositPool.rewardPerTokenStored;
        }
        uint nowTime = block.timestamp;
        uint rewardRate = getSupplyRate().div(DURATION);
        return
        depositPool.rewardPerTokenStored.add(
            nowTime
            .sub(depositPool.lastUpdateTime)
            .mul(rewardRate)
        );
    }

    function earned(address account) public view returns (uint256) {
        return
        balanceOf(account)
        .mul(rewardPerToken().sub(userDepositMap[account].userRewardPerTokenPaid))
        .div(1e18)
        .add(userDepositMap[account].rewards);
    }

    function stake(address referrer, uint256 amount) public updateInterest(0, address(0)) updateReward(msg.sender) {
        clear(0);
        address account = msg.sender;
        require(amount > 0, 'Cannot stake 0');
        _relationToken.bindRelationshipExternal(account, referrer);
        depositPool.totalSupply = depositPool.totalSupply.add(amount);
        userDepositMap[account].balance = userDepositMap[account].balance.add(amount);
        _token.transferFrom(account, address(this), amount);
        emit Staked(account, amount);
    }

    function withdraw(uint256 amount) public updateInterest(0, address(0)) updateReward(msg.sender) {
        clear(0);
        address account = msg.sender;
        require(amount > 0, 'Cannot withdraw 0!');
        require(amount <= withdrawalbe(account), 'Exceeds the withdrawal limit!');
        depositPool.totalSupply = depositPool.totalSupply.sub(amount);
        userDepositMap[account].balance = userDepositMap[account].balance.sub(amount);
        _token.transfer(account, amount);
        emit Withdrawn(account, amount);
    }

    function exit() external {
        withdraw(withdrawalbe(msg.sender));
        getReward();
    }

    function getReward() public updateReward(msg.sender) {
        clear(0);
        address account = msg.sender;
        uint256 reward = userDepositMap[account].rewards;
        if (reward > 0) {
            userDepositMap[account].rewards = 0;
            userDepositMap[account].rewardsPaid = userDepositMap[account].rewardsPaid.add(reward);
            uint256 amount = reward.mul(20).div(100);
            _rewardToken.transfer(account, reward.sub(amount));
            _rewardToken.transfer(address(_board), amount);
            _board.allocate(amount);
            emit RewardPaid(account, reward);
        }
    }
    
    function clearAddrs(uint256 poolId, address[] memory addrs) public{
        for(uint256 i=0;i<addrs.length;i++){
            clearAddr(poolId, addrs[i]);
        }
    }

    function clear(uint256 length) public {
        if(poolList.length == 0) return;
        clearPool(clearIndex, length);
    }

    function clearPool(uint256 poolId, uint256 length) public {
        if(userListMap[poolId].length == 0){
            clearIndex++;
            if(clearIndex >= poolList.length) clearIndex = 0;
            return;
        }
        if(length == 0 && clearNumber==0) return;
        if(length == 0) length = clearNumber;
        for(uint256 i=0;i<length;i++){
            clearAddr(poolId, userListMap[poolId][poolList[poolId].index]);
            poolList[poolId].index++;
            if(poolList[poolId].index>=userListMap[poolId].length){
                poolList[poolId].index = 0;
                clearIndex++;
                if(clearIndex >= poolList.length) clearIndex = 0;
            }
        }
    }

    function clearAddr(uint poolId, address account) public updateInterest(poolId, account) {
        uint256 total = userBorrowMap[poolId][account].principal;
        uint256 balance = userBorrowMap[poolId][account].balance;
        if(total==0) return;
        if(poolId==0){
            uint256 borrowed = userDepositMap[account].borrowed;
            if(total >= borrowed.mul(99).div(100)){
                update(account);
                userDepositMap[account].borrowed = 0;
                userDepositMap[account].balance = userDepositMap[account].balance.sub(borrowed);
                depositPool.totalSupply = depositPool.totalSupply.sub(borrowed);

                totalClearDeposit = totalClearDeposit.add(total);
                totalClearBorrowed = totalClearBorrowed.add(borrowed);
                (,poolList[poolId].totalSupply) = poolList[poolId].totalSupply.trySub(total);
                clearInternal(poolId, account, balance, total);
            }
        }else{
            uint256 clearBalance = balance.mul(100).div(poolList[poolId].borrowFactor);
            if(total >= clearBalance){
                totalClearReleased = totalClearReleased.add(total);
                poolList[poolId].totalSupply = poolList[poolId].totalSupply.sub(balance);
                clearInternal(poolId, account, balance, total);
            }
        }
    }

    function clearInternal(uint poolId, address account, uint256 balance, uint256 total) private{
        userBorrowMap[poolId][account].principal = 0;
        userBorrowMap[poolId][account].balance = 0;
        (,borrowPool.totalSupply) = borrowPool.totalSupply.trySub(total);
        emit Clear(account, poolList[poolId].pool, total);
        ClearInfo memory clearInfo = ClearInfo({
            account: account,
            pool: poolList[poolId].pool,
            balance: balance,
            interest: total.sub(balance),
            time: block.timestamp
        });
        clearList.push(clearInfo);
        clearListMap[account].push(clearInfo);
    }

    function getTotalClear() public view returns(uint256, uint256, uint256){
        return (totalClearReleased, totalClearDeposit, totalClearBorrowed);
    }
    
    function getPoolLength() public view returns(uint){
        return poolList.length;
    }
    
    function getUserLength(uint256 poolId) public view returns(uint){
        return userListMap[poolId].length;
    }

    function getList(uint start, uint length) public view 
    returns(uint256[] memory totals, bool[] memory isValids, uint256[] memory borrowFactors, uint256[] memory clearFactors){
        uint256 minLength = (start+length).min(poolList.length);
        totals = new uint256[](minLength);
        isValids = new bool[](minLength);
        borrowFactors = new uint256[](minLength);
        clearFactors = new uint256[](minLength);
        BorrowListInfo memory pool;
        for(uint i=start; i<minLength; i++){
            pool = poolList[i];
            totals[i-start] = pool.totalSupply;
            isValids[i-start] = pool.isValid;
            borrowFactors[i-start] = pool.borrowFactor;
            clearFactors[i-start] = pool.clearFactor;
        }
        return (totals, isValids, borrowFactors, clearFactors);
    }

    function getListExtra(uint start, uint length) public view 
    returns(address[] memory addrs, uint256[] memory idxs, uint256[] memory lengths){
        uint256 minLength = (start+length).min(poolList.length);
        addrs = new address[](minLength);
        idxs = new uint256[](minLength);
        lengths = new uint256[](minLength);
        BorrowListInfo memory pool;
        for(uint i=start; i<minLength; i++){
            pool = poolList[i];
            addrs[i-start] = pool.pool;
            idxs[i-start] = pool.index;
            lengths[i-start] = userListMap[i].length;
        }
        return (addrs, idxs, lengths);
    }
    
    function getListInfo(uint start, uint length, address account) public view 
    returns(uint256[] memory balances, uint256[] memory rewardsPaid, uint256[] memory rewards, uint256[] memory borrowables){
        uint256 minLength = (start+length).min(poolList.length);
        balances = new uint256[](minLength);
        rewardsPaid = new uint256[](minLength);
        rewards = new uint256[](minLength);
        borrowables = new uint256[](minLength);
        UserBorrowInfo memory user;
        for(uint i=start; i<minLength; i++){
            user = userBorrowMap[i][account];
            balances[i-start] = user.balance;
            rewardsPaid[i-start] = user.rewardsPaid;
            if(user.principal > 0){
                rewards[i-start] = owed(i, account);
            }
            if(i==0) borrowables[i-start] = userDepositMap[account].balance.sub(userDepositMap[account].borrowed);
            else borrowables[i-start] = IPool(poolList[i].pool).getBorrowable(account);
        }
        return (balances, rewardsPaid, rewards, borrowables);
    }
    
    function getClearLength() public view returns(uint){
        return clearList.length;
    }
    
    function getUserClearLength(address account) public view returns(uint){
        return clearListMap[account].length;
    }

    function getClearList(uint start, uint length) public view 
    returns(address[] memory accounts, address[] memory pools, uint256[] memory balances, uint256[] memory interests, uint256[] memory times){
        uint256 minLength = (start+length).min(clearList.length);
        accounts = new address[](minLength);
        pools = new address[](minLength);
        balances = new uint256[](minLength);
        interests = new uint256[](minLength);
        times = new uint256[](minLength);
        ClearInfo memory clearInfo;
        for(uint i=start; i<minLength; i++){
            clearInfo = clearList[i];
            accounts[i-start] = clearInfo.account;
            pools[i-start] = clearInfo.pool;
            balances[i-start] = clearInfo.balance;
            interests[i-start] = clearInfo.interest;
            times[i-start] = clearInfo.time;
        }
        return (accounts, pools, balances, interests, times);
    }

    function getUserClearList(address account, uint start, uint length) public view 
    returns(address[] memory accounts, address[] memory pools, uint256[] memory balances, uint256[] memory interests, uint256[] memory times){
        uint256 minLength = (start+length).min(clearListMap[account].length);
        accounts = new address[](minLength);
        pools = new address[](minLength);
        balances = new uint256[](minLength);
        interests = new uint256[](minLength);
        times = new uint256[](minLength);
        ClearInfo memory clearInfo;
        for(uint i=start; i<minLength; i++){
            clearInfo = clearListMap[account][i];
            accounts[i-start] = clearInfo.account;
            pools[i-start] = clearInfo.pool;
            balances[i-start] = clearInfo.balance;
            interests[i-start] = clearInfo.interest;
            times[i-start] = clearInfo.time;
        }
        return (accounts, pools, balances, interests, times);
    }
    
    function recoverWrongToken(address tokenAddress, uint256 amount) external onlyOwner{
        require(tokenAddress!=address(_rewardToken), "Cannot be rewardToken!");
        IERC20(tokenAddress).transfer(address(msg.sender), amount);
    }
}
