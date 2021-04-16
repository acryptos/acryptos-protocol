//Copied and modified from: https://raw.githubusercontent.com/sushiswap/sushiswap/1e4db47fa313f84cd242e17a4972ec1e9755609a/contracts/MasterChef.sol
//remove migrator
//changeable reward parameters
//withdrawal fee - goes to acsACS
//acsACSReward gets minted like devReward, initially 33% of supply, 10% for dev
//v2 - harvest charges withdrawal fee. stake/unstake no longer harvests, harvestToVault directly
//ACryptoSChef
// - remove and clean up harvestToVault, bonus multiplier, massUpdate
// - generalize additional emissions into array
// - add strategist that can add new pools
// - add concept of weight to user deposits and pools
//v2b
// - add withdrawal fee
// - add additional pool rewards

pragma solidity 0.6.12;


import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

interface ERC20Mintable {
  function addMinter ( address account ) external;
  function allowance ( address owner, address spender ) external view returns ( uint256 );
  function approve ( address spender, uint256 amount ) external returns ( bool );
  function balanceOf ( address account ) external view returns ( uint256 );
  function decimals (  ) external view returns ( uint8 );
  function decreaseAllowance ( address spender, uint256 subtractedValue ) external returns ( bool );
  function increaseAllowance ( address spender, uint256 addedValue ) external returns ( bool );
  function isMinter ( address account ) external view returns ( bool );
  function mint ( address account, uint256 amount ) external returns ( bool );
  function name (  ) external view returns ( string memory );
  function renounceMinter (  ) external;
  function symbol (  ) external view returns ( string memory );
  function totalSupply (  ) external view returns ( uint256 );
  function transfer ( address recipient, uint256 amount ) external returns ( bool );
  function transferFrom ( address sender, address recipient, uint256 amount ) external returns ( bool );
}

contract ACryptoSFarmV2b_ACSI is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 weight;     // Weight of LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardCredit;
        //
        // We do some fancy math here. Basically, any point in time, the amount of SUSHIs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSushiPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSushiPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 totalWeight;      // Total weight of LP tokens users have provided. Used to implement acsACS boost.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SUSHIs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SUSHIs distribution occurs.
        uint256 accSushiPerShare; // Accumulated SUSHIs per share, times 1e12. See below.
        uint256 withdrawalFee;
    }

    // Used to distribute set % rewards to dev, treasury, ACS Vault and others in future.
    struct AdditionalReward {
        address to;           // Address to receive reward
        uint256 reward;       // divided by REWARD_DENOMINATOR
    }

    // The SUSHI TOKEN!
    ERC20Mintable public sushi;
    // SUSHI tokens created per block.
    uint256 public sushiPerBlock;

    address public strategist;
    address public harvestFeeAddress;
    uint256 public harvestFee;
    uint256 public maxBoost;
    uint256 public boostFactor;
    address public boostToken;

    uint256 public constant REWARD_DENOMINATOR = 10000;
    AdditionalReward[] public additionalRewards;

    // Info of each pool.
    mapping (address => PoolInfo) public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (address => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    struct AdditionalPoolReward {
        address rewardToken;  // token to give as additional reward
        address from;         // address to take rewardToken from, must approve contract to spend
        uint256 rewardFactor; // rewardAmount = pendingSushi.mul(rewardFactor).div(REWARD_DENOMINATOR)
    }
    mapping (address => AdditionalPoolReward[]) public additionalPoolRewards;

    // End of storage  



    event Deposit(address indexed user, address indexed lpToken, uint256 amount);
    event Withdraw(address indexed user, address indexed lpToken, uint256 amount);

    function initialize() public initializer {
        __Ownable_init();
        transferOwnership(address(0x3595D94a7AA78292b4283fd541ce3ea45AFeC1bc)); //timelockShort

        sushi = ERC20Mintable(address(0x5b17b4d5e4009B5C43e3e3d63A5229F794cBA389)); //ACSI
        strategist = address(0xB9a81e121d8C9D619682bB9dDB6823439178F2f8); //deployer
        harvestFeeAddress = address(0x7232e1f646B14edFC263E04311729cCfE0ef20Fb); //acsACSI Strategy
        // sushiPerBlock = 88888888888888888;
        sushiPerBlock = 2222222222222222;
        harvestFee = 0.06e18;
        maxBoost = 25000; //divided by REWARD_DENOMINATOR
        boostFactor = 15000; //divided by REWARD_DENOMINATOR
        boostToken = address(0x2b66399AD01be47C5aa11C48fDd6DF689DAE929A); //acsACSI
        additionalRewards.push(AdditionalReward({
            to: address(0xB9a81e121d8C9D619682bB9dDB6823439178F2f8), //deployer
            reward: 1000
        }));
        additionalRewards.push(AdditionalReward({
            to: address(0x2b66399AD01be47C5aa11C48fDd6DF689DAE929A), //acsACSI Vault
            reward: 3333
        }));
        // additionalRewards.push(AdditionalReward({
        //     to: address(0x5BD97307A40DfBFDBAEf4B3d997ADB816F2dadCC), //treasury
        //     reward: 300
        // }));
    }

    // View function to see pending SUSHIs on frontend.
    function pendingSushi(address _lpToken, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_lpToken];
        UserInfo storage user = userInfo[_lpToken][_user];
        uint256 accSushiPerShare = pool.accSushiPerShare;
        if (block.number > pool.lastRewardBlock && pool.totalWeight != 0) {
            uint256 sushiReward = block.number.sub(pool.lastRewardBlock).mul(sushiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accSushiPerShare = accSushiPerShare.add(sushiReward.mul(1e12).div(pool.totalWeight));
        }
        return user.weight.mul(accSushiPerShare).div(1e12).sub(user.rewardDebt).add(user.rewardCredit);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(address _lpToken) public {
        PoolInfo storage pool = poolInfo[_lpToken];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.totalWeight == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 sushiReward = block.number.sub(pool.lastRewardBlock).mul(sushiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        if (sushiReward > 0) {
            for (uint256 i = 0; i < additionalRewards.length; ++i) {
                sushi.mint(additionalRewards[i].to, sushiReward.mul(additionalRewards[i].reward).div(REWARD_DENOMINATOR));
            }

            sushi.mint(address(this), sushiReward);
            pool.accSushiPerShare = pool.accSushiPerShare.add(sushiReward.mul(1e12).div(pool.totalWeight));
        }
        pool.lastRewardBlock = block.number;
    }

    // Used to display user's future boost in UI
    function calculateWeight(address _lpToken, address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_lpToken][_user];
        uint256 _weight = IERC20Upgradeable(_lpToken).balanceOf(address(this))
            .mul(boostFactor)
            .mul(IERC20Upgradeable(boostToken).balanceOf(_user))
            .div(IERC20Upgradeable(boostToken).totalSupply())
            .div(REWARD_DENOMINATOR)
            .add(user.amount);
        uint256 _maxWeight = user.amount.mul(maxBoost).div(REWARD_DENOMINATOR);

        return _weight > _maxWeight ? _maxWeight : _weight;
    }

    // Deposit LP tokens to MasterChef for SUSHI allocation.
    function deposit(address _lpToken, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_lpToken];
        UserInfo storage user = userInfo[_lpToken][msg.sender];
        updatePool(_lpToken);
        user.rewardCredit = user.weight.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt).add(user.rewardCredit);
        if(_amount > 0) {
            IERC20Upgradeable(_lpToken).safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        pool.totalWeight = pool.totalWeight.sub(user.weight);
        user.weight = calculateWeight(_lpToken, msg.sender);
        pool.totalWeight = pool.totalWeight.add(user.weight);
        user.rewardDebt = user.weight.mul(pool.accSushiPerShare).div(1e12);
        emit Deposit(msg.sender, _lpToken, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(address _lpToken, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_lpToken];
        UserInfo storage user = userInfo[_lpToken][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_lpToken);
        user.rewardCredit = user.weight.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt).add(user.rewardCredit);
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uint256 _fee = _amount.mul(pool.withdrawalFee).div(REWARD_DENOMINATOR);
            if(_fee > 0) {
                IERC20Upgradeable(_lpToken).safeTransfer(harvestFeeAddress, _fee);
            }
            IERC20Upgradeable(_lpToken).safeTransfer(address(msg.sender), _amount.sub(_fee));
        }
        pool.totalWeight = pool.totalWeight.sub(user.weight);
        user.weight = calculateWeight(_lpToken, msg.sender);
        pool.totalWeight = pool.totalWeight.add(user.weight);
        user.rewardDebt = user.weight.mul(pool.accSushiPerShare).div(1e12);
        emit Withdraw(msg.sender, _lpToken, _amount);
    }

    function harvest(address _lpToken) public {
        PoolInfo storage pool = poolInfo[_lpToken];
        UserInfo storage user = userInfo[_lpToken][msg.sender];
        updatePool(_lpToken);
        uint256 pending = user.weight.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt).add(user.rewardCredit);
        user.rewardCredit=0;
        if(pending > 0) {
            if(pending < harvestFee) {
                safeSushiTransfer(harvestFeeAddress, pending);
            } else {
                safeSushiTransfer(harvestFeeAddress, harvestFee);
                safeSushiTransfer(msg.sender, pending.sub(harvestFee));
            }

            for (uint256 i = 0; i < additionalPoolRewards[_lpToken].length; ++i) {
                safeAdditionalPoolRewardTransfer(
                    msg.sender,
                    pending.mul(additionalPoolRewards[_lpToken][i].rewardFactor).div(REWARD_DENOMINATOR),
                    additionalPoolRewards[_lpToken][i].rewardToken,
                    additionalPoolRewards[_lpToken][i].from
                );
            }
        }
        pool.totalWeight = pool.totalWeight.sub(user.weight);
        user.weight = calculateWeight(_lpToken, msg.sender);
        pool.totalWeight = pool.totalWeight.add(user.weight);
        user.rewardDebt = user.weight.mul(pool.accSushiPerShare).div(1e12);
    }

    // Safe sushi transfer function, just in case if rounding error causes pool to not have enough SUSHIs.
    function safeSushiTransfer(address _to, uint256 _amount) internal {
        uint256 sushiBal = sushi.balanceOf(address(this));
        if (_amount > sushiBal) {
            sushi.transfer(_to, sushiBal);
        } else {
            sushi.transfer(_to, _amount);
        }
    }

    function safeAdditionalPoolRewardTransfer(address _to, uint256 _amount, address _rewardToken, address _from) internal {
        uint256 _rewardTokenBalance = IERC20Upgradeable(_rewardToken).balanceOf(_from);
        uint256 _rewardTokenAllowance = IERC20Upgradeable(_rewardToken).allowance(_from,address(this));
        if (_amount > _rewardTokenBalance) _amount = _rewardTokenBalance;
        if (_amount > _rewardTokenAllowance) _amount = _rewardTokenAllowance;
        IERC20Upgradeable(_rewardToken).transferFrom(_from, _to, _amount);
    }

    function setSushiPerBlock(uint256 _sushiPerBlock) external onlyOwner {
        sushiPerBlock = _sushiPerBlock;
    }

    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
    }

    function addAdditionalReward(address _to, uint256 _reward) external onlyOwner {
        additionalRewards.push(AdditionalReward({
            to: _to,
            reward: _reward
        }));
    }

    function deleteAdditionalRewards() external onlyStrategist {
        delete additionalRewards;
    }

    // Update the given pool's SUSHI allocation point.
    function set(address _lpToken, uint256 _allocPoint, uint256 _withdrawalFee) public onlyStrategist {
        updatePool(_lpToken);
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_lpToken].allocPoint).add(_allocPoint);
        poolInfo[_lpToken].allocPoint = _allocPoint;
        poolInfo[_lpToken].withdrawalFee = _withdrawalFee;
    }

    function setHarvestFeeAddress(address _harvestFeeAddress) external onlyStrategist {
        harvestFeeAddress = _harvestFeeAddress;
    }

    function setHarvestFee(uint256 _harvestFee) external onlyStrategist {
        harvestFee = _harvestFee;
    }

    function setMaxBoost(uint256 _maxBoost) external onlyStrategist {
        maxBoost = _maxBoost;
    }

    function setBoostFactor(uint256 _boostFactor) external onlyStrategist {
        boostFactor = _boostFactor;
    }

    function additionalPoolRewardsLength(address _lpToken) external view returns (uint256) {
        return additionalPoolRewards[_lpToken].length;
    }

    function addAdditionalPoolReward(address _lpToken, address _rewardToken, address _from, uint256 _rewardFactor) external onlyStrategist {
        additionalPoolRewards[_lpToken].push(AdditionalPoolReward({
            rewardToken: _rewardToken,
            from: _from,
            rewardFactor: _rewardFactor
        }));
    }

    function deleteAdditionalPoolRewards(address _lpToken) external onlyStrategist {
        delete additionalPoolRewards[_lpToken];
    }

    modifier onlyStrategist() {
        require(_msgSender() == strategist || owner() == _msgSender(), "!strategist");
        _;
    }

}