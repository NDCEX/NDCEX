// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './lib/IERC20.sol';
import './lib/SafeERC20.sol';
import './lib/Ownable.sol';

contract ShareWrapper {
    uint256 _totalSupply;
    mapping(address => uint256) _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
}

contract Board is ShareWrapper, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using SafeMath for uint112;

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 rewardPaid;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    IERC20 public stakedToken;
    IERC20 public rewardToken;

    mapping(address => Boardseat) private directors;
    BoardSnapshot[] private boardHistory;
    mapping(uint256 => uint256) public rewardTotalHistory;
    mapping(uint256 => mapping(address => uint256)) public rewardHistory;
    uint256 public totalReward;
    uint256 public constant startTime = 1637856000;
    
    mapping(address => bool) public operators;

    constructor(address _stakedToken, address _rewardToken) public {
        require(_stakedToken != address(0), "Zero address!");
        require(_rewardToken != address(0), "Zero address!");
        stakedToken = IERC20(_stakedToken);
        rewardToken = IERC20(_rewardToken);
        
        BoardSnapshot memory genesisSnapshot = BoardSnapshot({
            time : block.number,
            rewardReceived : 0,
            rewardPerShare : 0
        });
        boardHistory.push(genesisSnapshot);
    }
    
    function setOperator(address[] memory operatorList, bool flag) external onlyOwner{
        for(uint256 i=0;i<operatorList.length;i++){
            operators[operatorList[i]] = flag;
        }
        emit SetOperator(operatorList, flag);
    }
    
    modifier onlyOperator() {
        require(operators[msg.sender], 'Boardroom: Caller is not the operator');
        _;
    }

    modifier directorExists {
        require(
            balanceOf(msg.sender) > 0,
            'Boardroom: The director does not exist'
        );
        _;
    }

    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director) public view returns (uint256){
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director) internal view returns (BoardSnapshot memory) {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return
        balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(
            directors[director].rewardEarned
        );
    }

    function getRewardPaid(address director) public view returns(uint256){
        return directors[director].rewardPaid;
    }

    function getTodayReward(address director) public view returns(uint256){
        return rewardHistory[getIndex()][director];
    }

    function getIndex() public view returns(uint256){
        return block.timestamp.sub(startTime).div(1 days);
    }

    function getTodayTotalReward() public view returns(uint256){
        return rewardTotalHistory[getIndex()];
    }

    /* =========== MUTATIVE FUNCTIONS =========== */
    function stake(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, 'Boardroom: Cannot stake 0');
        address account = msg.sender;
        stakedToken.safeTransferFrom(account, address(this), amount);
        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Staked(account, amount);
    }

    function withdraw(uint256 amount) public directorExists updateReward(msg.sender) {
        address account = msg.sender;
        stakedToken.safeTransfer(account, amount);
        require(amount > 0, 'Boardroom: Cannot withdraw 0');
        uint256 directorShare = _balances[account];
        require(
            directorShare >= amount,
            'Boardroom: withdraw request greater than staked amount'
        );
        _totalSupply = _totalSupply.sub(amount);
        _balances[account] = directorShare.sub(amount);
        emit Withdrawn(account, amount);
    }

    function getReward() public updateReward(msg.sender) {
        address account = msg.sender;
        uint256 reward = directors[account].rewardEarned;
        if (reward > 0) {
            directors[account].rewardEarned = 0;
            directors[account].rewardPaid = directors[account].rewardPaid.add(reward);
            rewardHistory[getIndex()][account] = rewardHistory[getIndex()][account].add(reward);
            rewardToken.safeTransfer(account, reward);
            emit RewardPaid(account, reward);
        }
    }

    function addNewSnapshot(uint256 amount) private {
        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time : block.number,
            rewardReceived : amount,
            rewardPerShare : nextRPS
        });
        boardHistory.push(newSnapshot);
    }

    function allocateWithToken(uint256 amount) external {
        require(amount > 0, 'Boardroom: Cannot allocate 0');
        if (totalSupply() > 0) {
            addNewSnapshot(amount);
            rewardToken.safeTransferFrom(msg.sender, address(this), amount);
            emit RewardAdded(msg.sender, amount);
            rewardTotalHistory[getIndex()] = rewardTotalHistory[getIndex()].add(amount);
            totalReward = totalReward.add(amount);
        }
    }
    
    function allocate(uint256 amount) external onlyOperator {
        require(amount > 0, 'Boardroom: Cannot allocate 0');
        if (totalSupply() > 0) {
            addNewSnapshot(amount);
            emit RewardAdded(msg.sender, amount);
            rewardTotalHistory[getIndex()] = rewardTotalHistory[getIndex()].add(amount);
            totalReward = totalReward.add(amount);
        }
    }
    
    function recoverWrongToken(address tokenAddress, uint256 amount) external onlyOwner{
        require(tokenAddress!=address(stakedToken), "Cannot be stakedToken!");
        require(tokenAddress!=address(rewardToken), "Cannot be rewardToken!");
        IERC20(tokenAddress).safeTransfer(address(msg.sender), amount);
        emit RecoverWrongToken(tokenAddress, amount);
    }

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
    event SetOperator(address[] operatorList, bool flag);
    event RecoverWrongToken(address indexed tokenAddress, uint256 amount);
}
