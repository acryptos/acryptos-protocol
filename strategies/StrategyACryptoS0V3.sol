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
}

contract StrategyACryptoS0V3 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant want = address(0x4197C6EF3879a08cD51e5560da5064B773aa1d29); //ACS
    address public constant pancakeSwapRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);

    struct PairToLiquidate {
        address pair;
        address tokenA;
        address tokenB;
        address router;
    }
    struct TokenToSwap {
        address tokenIn;
        address tokenOut;
        address router;
    }
    address[] public ssToWithdraw; //StableSwap pools to withdraw admin fees from
    PairToLiquidate[] public pairsToLiquidate;
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

      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0x7561EEe90e24F3b348E1087A005F78B4c8453524), //btc-bnb
        tokenA: address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c), //btcb
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0x70D8929d04b60Af4fb9B58713eBcf18765aDE422), //eth-bnb
        tokenA: address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8), //eth
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0x41182c32F854dd97bA0e0B1816022e0aCB2fc0bb), //xvs-bnb
        tokenA: address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63), //xvs
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0x752E713fB70E3FA1Ac08bCF34485F14A986956c4), //sxp-bnb
        tokenA: address(0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A), //sxp
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0x1B96B92314C44b159149f7E0303511fB2Fc4774f), //busd-bnb
        tokenA: address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56), //busd
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      pairsToLiquidate.push(PairToLiquidate({
        pair: address(0xA527a61703D82139F8a06Bc30097cC9CAA2df5A6), //cake-bnb
        tokenA: address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82), //cake
        tokenB: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));

      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82), //cake
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c), //btc
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8), //eth
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63), //xvs
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
      }));
      tokensToSwap0.push(TokenToSwap({
        tokenIn: address(0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A), //sxp
        tokenOut: address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), //wbnb
        router: address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F) //pancake
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
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoS0V3";
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

      for (uint i=0; i<pairsToLiquidate.length; i++) {
        _liquidatePair(pairsToLiquidate[i].pair, pairsToLiquidate[i].tokenA, pairsToLiquidate[i].tokenB, pairsToLiquidate[i].router);
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

    function deletePairsToLiquidate() external {
      require(msg.sender == governance, "!governance");
      delete pairsToLiquidate;
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
