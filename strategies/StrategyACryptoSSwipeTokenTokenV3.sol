pragma solidity ^0.5.17;

import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/IERC20.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/SafeMath.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/Math.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/utils/Address.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/SafeERC20.sol";

import "../../interfaces/yearn/IController.sol";
import "../../interfaces/yearn/Token.sol";

interface SwipeChef {
  function BONUS_MULTIPLIER (  ) external view returns ( uint256 );
  function add ( uint256 _allocPoint, address _lpToken, bool _withUpdate ) external;
  function bonusEndBlock (  ) external view returns ( uint256 );
  function deposit ( uint256 _pid, uint256 _amount ) external;
  function dev ( address _devaddr ) external;
  function devaddr (  ) external view returns ( address );
  function emergencyWithdraw ( uint256 _pid ) external;
  function getMultiplier ( uint256 _from, uint256 _to ) external view returns ( uint256 );
  function massUpdatePools (  ) external;
  function migrate ( uint256 _pid ) external;
  function migrator (  ) external view returns ( address );
  function owner (  ) external view returns ( address );
  function pendingSwipe ( uint256 _pid, address _user ) external view returns ( uint256 );
  function poolInfo ( uint256 ) external view returns ( address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accSwipePerShare );
  function poolLength (  ) external view returns ( uint256 );
  function renounceOwnership (  ) external;
  function set ( uint256 _pid, uint256 _allocPoint, bool _withUpdate ) external;
  function setMigrator ( address _migrator ) external;
  function setSwipePerBlock ( uint256 speed ) external;
  function startBlock (  ) external view returns ( uint256 );
  function swipe (  ) external view returns ( address );
  function swipePerBlock (  ) external view returns ( uint256 );
  function totalAllocPoint (  ) external view returns ( uint256 );
  function transferOwnership ( address newOwner ) external;
  function updatePool ( uint256 _pid ) external;
  function userInfo ( uint256, address ) external view returns ( uint256 amount, uint256 rewardDebt );
  function withdraw ( uint256 _pid, uint256 _amount ) external;
}

interface SwipeSwapRouter {
  function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

  function addLiquidity(
      address tokenA,
      address tokenB,
      uint amountADesired,
      uint amountBDesired,
      uint amountAMin,
      uint amountBMin,
      address to,
      uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

  function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

contract StrategyACryptoSSwipeTokenTokenV3 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant swipe = address(0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A);
    address public constant swipeChef = address(0xe6421c0CC2d647be51c11AE952927aB38Dd6f753);
    address public constant swipeSwapRouter = address(0x816278BbBCc529f8cdEE8CC72C226fb01def6E6C);

    address public want;
    address public tokenA;
    address public tokenB;
    uint256 public swipeChefPid;
    address[] public swipeToTokenAPath;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public performanceFee = 450;
    uint256 public strategistReward = 50;
    uint256 public withdrawalFee = 50;
    uint256 public harvesterReward = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    bool public paused;

    constructor(address _governance, address _strategist, address _controller, address _want, address _tokenA, address _tokenB, uint256 _swipeChefPid, address[] memory _swipeToTokenAPath) public {
        want = _want;
        tokenA = _tokenA;
        tokenB = _tokenB;
        swipeChefPid = _swipeChefPid;
        swipeToTokenAPath = _swipeToTokenAPath;

        governance = _governance;
        strategist = _strategist;
        controller = _controller;
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoSSwipeTokenTokenV3";
    }

    function deposit() public {
      _stakeWant(false);
    }

    function _stakeWant(bool _force) internal {
      if(paused) return;
      uint256 _want = IERC20(want).balanceOf(address(this));
      if (_want > 0) {
        IERC20(want).safeApprove(swipeChef, 0);
        IERC20(want).safeApprove(swipeChef, _want);
      }
      if (_want > 0 || _force) {
        SwipeChef(swipeChef).deposit(swipeChefPid, _want);
      }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
      require(msg.sender == controller, "!controller");
      uint256 _balance = IERC20(want).balanceOf(address(this));
      if (_balance < _amount) {
          _amount = _withdrawSome(_amount.sub(_balance));
          _amount = _amount.add(_balance);
      }

      uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);
      IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
      SwipeChef(swipeChef).withdraw(swipeChefPid, _amount);

      return _amount;
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
      require(msg.sender == controller, "!controller");
      _withdrawAll();

      balance = IERC20(want).balanceOf(address(this));

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, balance);

      //waste not - send dust tokenA to rewards
      IERC20(tokenA).safeTransfer(IController(controller).rewards(),
          IERC20(tokenA).balanceOf(address(this))
        );

    }

    function _withdrawAll() internal {
      SwipeChef(swipeChef).emergencyWithdraw(swipeChefPid);
    }

    function _convertSwipeToWant() internal {
      if(swipe != tokenA) {
        uint256 _swipe = IERC20(swipe).balanceOf(address(this));
        if(_swipe > 0) {
          IERC20(swipe).safeApprove(swipeSwapRouter, 0);
          IERC20(swipe).safeApprove(swipeSwapRouter, _swipe);

          SwipeSwapRouter(swipeSwapRouter).swapExactTokensForTokens(_swipe, uint256(0), swipeToTokenAPath, address(this), now.add(1800));
        }
      }
      uint256 _tokenA = IERC20(tokenA).balanceOf(address(this));
      if(_tokenA > 0) {
        //convert tokenA
        IERC20(tokenA).safeApprove(swipeSwapRouter, 0);
        IERC20(tokenA).safeApprove(swipeSwapRouter, _tokenA.div(2));

        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;

        SwipeSwapRouter(swipeSwapRouter).swapExactTokensForTokens(_tokenA.div(2), uint256(0), path, address(this), now.add(1800));

        //add liquidity
        _tokenA = IERC20(tokenA).balanceOf(address(this));
        uint256 _tokenB = IERC20(tokenB).balanceOf(address(this));

        IERC20(tokenA).safeApprove(swipeSwapRouter, 0);
        IERC20(tokenA).safeApprove(swipeSwapRouter, _tokenA);
        IERC20(tokenB).safeApprove(swipeSwapRouter, 0);
        IERC20(tokenB).safeApprove(swipeSwapRouter, _tokenB);

        SwipeSwapRouter(swipeSwapRouter).addLiquidity(
          tokenA, // address tokenA,
          tokenB, // address tokenB,
          _tokenA, // uint amountADesired,
          _tokenB, // uint amountBDesired,
          0, // uint amountAMin,
          0, // uint amountBMin,
          address(this), // address to,
          now.add(1800)// uint deadline
        );
      }
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfStakedWant() public view returns (uint256) {
      (uint256 _amount,) = SwipeChef(swipeChef).userInfo(swipeChefPid,address(this));
      return _amount;
    }

    function harvest() public returns (uint harvesterRewarded) {
      require(msg.sender == tx.origin, "not eoa");

      _stakeWant(true);

      uint _swipe = IERC20(swipe).balanceOf(address(this)); 
      uint256 _harvesterReward;
      if (_swipe > 0) {
        uint256 _fee = _swipe.mul(performanceFee).div(FEE_DENOMINATOR);
        uint256 _reward = _swipe.mul(strategistReward).div(FEE_DENOMINATOR);
        _harvesterReward = _swipe.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20(swipe).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(swipe).safeTransfer(strategist, _reward);
        IERC20(swipe).safeTransfer(msg.sender, _harvesterReward);
      }

      _convertSwipeToWant();
      _stakeWant(false);

      return _harvesterReward;
    }

    function balanceOf() public view returns (uint256) {
      return balanceOfWant()
        .add(balanceOfStakedWant());
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setPerformanceFee(uint256 _performanceFee) external {
        require(msg.sender == governance, "!governance");
        performanceFee = _performanceFee;
    }

    function setStrategistReward(uint256 _strategistReward) external {
        require(msg.sender == governance, "!governance");
        strategistReward = _strategistReward;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!governance");
        withdrawalFee = _withdrawalFee;
    }

    function setHarvesterReward(uint256 _harvesterReward) external {
        require(msg.sender == governance, "!governance");
        harvesterReward = _harvesterReward;
    }

    function pause() external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        _withdrawAll();
        paused = true;
    }

    function unpause() external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        paused = false;
        _stakeWant(false);
    }


    //In case anything goes wrong - Swipe Swap has migrator function and we have no guarantees how it might be used.
    //This does not increase user risk. Governance already controls funds via strategy upgrade, and is behind timelock and/or multisig.
    function executeTransaction(address target, uint value, string memory signature, bytes memory data) public payable returns (bytes memory) {
        require(msg.sender == governance, "!governance");

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call.value(value)(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        return returnData;
    }
}
