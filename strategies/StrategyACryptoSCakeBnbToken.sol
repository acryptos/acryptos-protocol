pragma solidity ^0.5.17;

import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/IERC20.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/SafeMath.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/Math.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/utils/Address.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/SafeERC20.sol";

// import "../../interfaces/curve/Curve.sol";
// import "../../interfaces/curve/Mintr.sol";

import "../../interfaces/yearn/IController.sol";
import "../../interfaces/yearn/Token.sol";

interface CakeChef {
  function BONUS_MULTIPLIER (  ) external view returns ( uint256 );
  function add ( uint256 _allocPoint, address _lpToken, bool _withUpdate ) external;
  function cake (  ) external view returns ( address );
  function cakePerBlock (  ) external view returns ( uint256 );
  function deposit ( uint256 _pid, uint256 _amount ) external;
  function dev ( address _devaddr ) external;
  function devaddr (  ) external view returns ( address );
  function emergencyWithdraw ( uint256 _pid ) external;
  function enterStaking ( uint256 _amount ) external;
  function getMultiplier ( uint256 _from, uint256 _to ) external view returns ( uint256 );
  function leaveStaking ( uint256 _amount ) external;
  function massUpdatePools (  ) external;
  function migrate ( uint256 _pid ) external;
  function migrator (  ) external view returns ( address );
  function owner (  ) external view returns ( address );
  function pendingCake ( uint256 _pid, address _user ) external view returns ( uint256 );
  function poolInfo ( uint256 ) external view returns ( address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accCakePerShare );
  function poolLength (  ) external view returns ( uint256 );
  function renounceOwnership (  ) external;
  function set ( uint256 _pid, uint256 _allocPoint, bool _withUpdate ) external;
  function setMigrator ( address _migrator ) external;
  function startBlock (  ) external view returns ( uint256 );
  function syrup (  ) external view returns ( address );
  function totalAllocPoint (  ) external view returns ( uint256 );
  function transferOwnership ( address newOwner ) external;
  function updateMultiplier ( uint256 multiplierNumber ) external;
  function updatePool ( uint256 _pid ) external;
  function userInfo ( uint256, address ) external view returns ( uint256 amount, uint256 rewardDebt );
  function withdraw ( uint256 _pid, uint256 _amount ) external;
}

interface PancakeSwapRouter {
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

contract StrategyACryptoSCakeBnbToken {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant cake = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public constant cakeChef = address(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    address public constant pancakeSwapRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);

    address public want;
    address public tokenB;
    uint256 public cakeChefPid;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public performanceFee = 450;
    uint256 public strategistReward = 50;
    uint256 public withdrawalFee = 50;
    uint256 public harvesterReward = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    constructor(address _controller, address _want, address _tokenB, uint256 _cakeChefPid) public {
        want = _want;
        tokenB = _tokenB;
        cakeChefPid = _cakeChefPid;

        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoSCakeBnbToken";
    }

    function deposit() public {
      uint256 _want = IERC20(want).balanceOf(address(this));
      if (_want > 0) {
        _stakeWant();
      }
    }

    function _stakeWant() internal {
      uint256 _want = IERC20(want).balanceOf(address(this));
      IERC20(want).safeApprove(cakeChef, 0);
      IERC20(want).safeApprove(cakeChef, _want);
      CakeChef(cakeChef).deposit(cakeChefPid, _want);
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
      CakeChef(cakeChef).withdraw(cakeChefPid, _amount);

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

      //waste not - send dust wbnb to rewards
      IERC20(wbnb).safeTransfer(IController(controller).rewards(),
          IERC20(wbnb).balanceOf(address(this))
        );

    }

    function _withdrawAll() internal {
      CakeChef(cakeChef).emergencyWithdraw(cakeChefPid);
    }

    function _convertCakeToWant() internal {
      uint256 _cake = IERC20(cake).balanceOf(address(this));
      if(_cake > 0 ) {
        _convertToken(_cake,cake,wbnb);
      }
      uint256 _wbnb = IERC20(wbnb).balanceOf(address(this));
      if(_wbnb > 0 ) {
        _convertToken(_wbnb.div(2),wbnb,tokenB);

        _wbnb = IERC20(wbnb).balanceOf(address(this));
        uint256 _tokenB = IERC20(tokenB).balanceOf(address(this));

        IERC20(wbnb).safeApprove(pancakeSwapRouter, 0);
        IERC20(wbnb).safeApprove(pancakeSwapRouter, _wbnb);
        IERC20(tokenB).safeApprove(pancakeSwapRouter, 0);
        IERC20(tokenB).safeApprove(pancakeSwapRouter, _tokenB);

        PancakeSwapRouter(pancakeSwapRouter).addLiquidity(
          wbnb, // address tokenA,
          tokenB, // address tokenB,
          _wbnb, // uint amountADesired,
          _tokenB, // uint amountBDesired,
          0, // uint amountAMin,
          0, // uint amountBMin,
          address(this), // address to,
          now.add(1800)// uint deadline
        );
      }
    }

    function _convertToken(uint _amount, address _tokenIn, address _tokenOut) internal {
        IERC20(_tokenIn).safeApprove(pancakeSwapRouter, 0);
        IERC20(_tokenIn).safeApprove(pancakeSwapRouter, _amount);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        PancakeSwapRouter(pancakeSwapRouter).swapExactTokensForTokens(_amount, uint256(0), path, address(this), now.add(1800));
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfStakedWant() public view returns (uint256) {
      (uint256 _amount,) = CakeChef(cakeChef).userInfo(cakeChefPid,address(this));
      return _amount;
    }

    function harvest() public returns (uint harvesterRewarded) {
      // require(msg.sender == strategist || msg.sender == governance, "!authorized");
      require(msg.sender == tx.origin, "not eoa");

      _stakeWant();

      uint _cake = IERC20(cake).balanceOf(address(this)); 
      uint256 _harvesterReward;
      if (_cake > 0) {
        uint256 _fee = _cake.mul(performanceFee).div(FEE_DENOMINATOR);
        uint256 _reward = _cake.mul(strategistReward).div(FEE_DENOMINATOR);
        _harvesterReward = _cake.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20(cake).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(cake).safeTransfer(strategist, _reward);
        IERC20(cake).safeTransfer(msg.sender, _harvesterReward);
      }

      _convertCakeToWant();
      _stakeWant();

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
}
