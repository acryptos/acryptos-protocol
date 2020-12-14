//V3.1 - remove const pancakeSwapRouter
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

interface IUniswapRouter {
  function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
  function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
  function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IStableSwap {
  function withdraw_admin_fees() external;
  function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_amount) external;
  function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);
  function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);
}

contract StrategyACryptoS0V4_ACSI {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant want = address(0x5b17b4d5e4009B5C43e3e3d63A5229F794cBA389); //ACSI

    struct PairToLiquidate {
        address pair;
        address tokenA;
        address tokenB;
        address router;
    }
    struct SsToLiquidate {
        address pool;
        address lpToken;
        int128 i;
    }
    struct TokenToSwap {
        address tokenIn;
        address tokenOut;
        address router;
    }
    struct SsTokenToSwap {
        address tokenIn;
        address pool;
        bool underlying;
        int128 i;
        int128 j;
    }
    address[] public ssToWithdraw; //StableSwap pools to withdraw admin fees from
    SsToLiquidate[] public ssToLiquidate;
    PairToLiquidate[] public pairsToLiquidate;
    SsTokenToSwap[] public ssTokensToSwap;
    TokenToSwap[] public tokensToSwap0;
    TokenToSwap[] public tokensToSwap1;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public withdrawalFee = 1000; //10%
    uint256 public harvesterReward = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    constructor(address _controller) public {
      governance = msg.sender;
      strategist = msg.sender;
      controller = _controller;

      ssToWithdraw.push(address(0xb3F0C9ea1F05e312093Fdb031E789A756659B0AC)); //ACS4 StableSwap
      ssToWithdraw.push(address(0x191409D5A4EfFe25b0f4240557BA2192D18a191e)); //ACS4VAI StableSwap

      ssToLiquidate.push(SsToLiquidate({
          pool: address(0xb3F0C9ea1F05e312093Fdb031E789A756659B0AC), //ACS4 StableSwap
          lpToken: address(0x83D69Ef5c9837E21E2389D47d791714F5771F29b), //ACS4
          i: 0
      }));

      ssTokensToSwap.push(SsTokenToSwap({
          tokenIn: address(0x55d398326f99059fF775485246999027B3197955), //usdt
          pool: address(0xb3F0C9ea1F05e312093Fdb031E789A756659B0AC), //ACS4 StableSwap
          underlying: false,
          i: 1,
          j: 0
      }));

      ssTokensToSwap.push(SsTokenToSwap({
          tokenIn: address(0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3), //dai
          pool: address(0xb3F0C9ea1F05e312093Fdb031E789A756659B0AC), //ACS4 StableSwap
          underlying: false,
          i: 2,
          j: 0
      }));

      ssTokensToSwap.push(SsTokenToSwap({
          tokenIn: address(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d), //usdc
          pool: address(0xb3F0C9ea1F05e312093Fdb031E789A756659B0AC), //ACS4 StableSwap
          underlying: false,
          i: 3,
          j: 0
      }));

      ssTokensToSwap.push(SsTokenToSwap({
          tokenIn: address(0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7), //vai
          pool: address(0x191409D5A4EfFe25b0f4240557BA2192D18a191e), //ACS4VAI StableSwap
          underlying: true,
          i: 0,
          j: 1
      }));

      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56), //busd
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      
      tokensToSwap1.push(TokenToSwap({
        tokenIn: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        tokenOut: address(0x4197C6EF3879a08cD51e5560da5064B773aa1d29), //acs
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      tokensToSwap1.push(TokenToSwap({
        tokenIn: address(0x4197C6EF3879a08cD51e5560da5064B773aa1d29), //acs
        tokenOut: address(0x5b17b4d5e4009B5C43e3e3d63A5229F794cBA389), //acsi
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoS0V3_1_ACSI";
    }

    function deposit() public {
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
          _amount = _balance;
      }

      uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
      require(msg.sender == controller, "!controller");

      balance = IERC20(want).balanceOf(address(this));

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, balance);
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function harvest() public returns (uint harvesterRewarded) {
      require(msg.sender == tx.origin, "not eoa");

      uint _before = IERC20(want).balanceOf(address(this));
      _convertAllToWant();
      uint _harvested = IERC20(want).balanceOf(address(this)).sub(_before);

      if (_harvested > 0) {
        uint256 _harvesterReward = _harvested.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20(want).safeTransfer(msg.sender, _harvesterReward);
        return _harvesterReward;
      }
    }


    function _convertAllToWant() internal {
      for (uint i=0; i<ssToWithdraw.length; i++) {
        IStableSwap(ssToWithdraw[i]).withdraw_admin_fees();
      }

      for (uint i=0; i<ssToLiquidate.length; i++) {
        uint256 _amount = IERC20(ssToLiquidate[i].lpToken).balanceOf(address(this));
        if(_amount > 0) {
          IERC20(ssToLiquidate[i].lpToken).safeApprove(ssToLiquidate[i].pool, 0);
          IERC20(ssToLiquidate[i].lpToken).safeApprove(ssToLiquidate[i].pool, _amount);
          IStableSwap(ssToLiquidate[i].pool).remove_liquidity_one_coin(_amount, ssToLiquidate[i].i, 0);
        }
      }

      for (uint i=0; i<pairsToLiquidate.length; i++) {
        _liquidatePair(pairsToLiquidate[i].pair, pairsToLiquidate[i].tokenA, pairsToLiquidate[i].tokenB, pairsToLiquidate[i].router);
      }

      for (uint i=0; i<ssTokensToSwap.length; i++) {
        uint256 _amount = IERC20(ssTokensToSwap[i].tokenIn).balanceOf(address(this));
        if(_amount > 0) {
          IERC20(ssTokensToSwap[i].tokenIn).safeApprove(ssTokensToSwap[i].pool, 0);
          IERC20(ssTokensToSwap[i].tokenIn).safeApprove(ssTokensToSwap[i].pool, _amount);
          if(ssTokensToSwap[i].underlying) {
            IStableSwap(ssTokensToSwap[i].pool).exchange_underlying(ssTokensToSwap[i].i, ssTokensToSwap[i].j, _amount, 0);            
          } else {
            IStableSwap(ssTokensToSwap[i].pool).exchange(ssTokensToSwap[i].i, ssTokensToSwap[i].j, _amount, 0);            
          }
        }
      }

      for (uint i=0; i<tokensToSwap0.length; i++) {
        _convertToken(tokensToSwap0[i].tokenIn, tokensToSwap0[i].tokenOut, tokensToSwap0[i].router);
      }

      for (uint i=0; i<tokensToSwap1.length; i++) {
        _convertToken(tokensToSwap1[i].tokenIn, tokensToSwap1[i].tokenOut, tokensToSwap1[i].router);
      }
    }

    function _liquidatePair(address _pair, address _tokenA, address _tokenB, address _router) internal {
      uint256 _amount = IERC20(_pair).balanceOf(address(this));
      if(_amount > 0 ) {
        IERC20(_pair).safeApprove(_router, 0);
        IERC20(_pair).safeApprove(_router, _amount);

        IUniswapRouter(_router).removeLiquidity(
            _tokenA, // address tokenA,
            _tokenB, // address tokenB,
            _amount, // uint liquidity,
            0, // uint amountAMin,
            0, // uint amountBMin,
            address(this), // address to,
            now.add(1800) // uint deadline
          );
      }
    }

    function _convertToken(address _tokenIn, address _tokenOut, address _router) internal {
      uint256 _amount = IERC20(_tokenIn).balanceOf(address(this));
      if(_amount > 0 ) {
        IERC20(_tokenIn).safeApprove(_router, 0);
        IERC20(_tokenIn).safeApprove(_router, _amount);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        IUniswapRouter(_router).swapExactTokensForTokens(_amount, uint256(0), path, address(this), now.add(1800));
      }
    }

    function balanceOf() public view returns (uint256) {
      return balanceOfWant();
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



    function addSsToWithdraw(address _ss) external {
      require(msg.sender == governance, "!governance");
      ssToWithdraw.push(_ss);
    }

    function addPairToLiquidate(address _pair, address _tokenA, address _tokenB, address _router) external {
      require(msg.sender == governance, "!governance");
      pairsToLiquidate.push(PairToLiquidate({
          pair: _pair,
          tokenA: _tokenA,
          tokenB: _tokenB,
          router: _router
      }));
    }

    function addSsToLiquidate(address _pool, address _lpToken, int128 _i) external {
      require(msg.sender == governance, "!governance");
      ssToLiquidate.push(SsToLiquidate({
          pool: _pool,
          lpToken: _lpToken,
          i: _i
      }));
    }

    function addSsTokenToSwap(address _tokenIn, address _pool, bool _underlying, int128 _i, int128 _j) external {
      require(msg.sender == governance, "!governance");
      ssTokensToSwap.push(SsTokenToSwap({
          tokenIn: _tokenIn,
          pool: _pool,
          underlying: _underlying,
          i: _i,
          j: _j
      }));
    }

    function addTokenToSwap0(address _tokenIn, address _tokenOut, address _router) external {
      require(msg.sender == governance, "!governance");
      tokensToSwap0.push(TokenToSwap({
          tokenIn: _tokenIn,
          tokenOut: _tokenOut,
          router: _router
      }));
    }

    function addTokenToSwap1(address _tokenIn, address _tokenOut, address _router) external {
      require(msg.sender == governance, "!governance");
      tokensToSwap1.push(TokenToSwap({
          tokenIn: _tokenIn,
          tokenOut: _tokenOut,
          router: _router
      }));
    }

    function deleteSsToWithdraw() external {
      require(msg.sender == governance, "!governance");
      delete ssToWithdraw;
    }

    function deleteSsToLiquidate() external {
      require(msg.sender == governance, "!governance");
      delete ssToLiquidate;
    }

    function deletePairsToLiquidate() external {
      require(msg.sender == governance, "!governance");
      delete pairsToLiquidate;
    }

    function deleteSsTokensToSwap() external {
      require(msg.sender == governance, "!governance");
      delete ssTokensToSwap;
    }

    function deleteTokensToSwap0() external {
      require(msg.sender == governance, "!governance");
      delete tokensToSwap0;
    }

    function deleteTokensToSwap1() external {
      require(msg.sender == governance, "!governance");
      delete tokensToSwap1;
    }
}
