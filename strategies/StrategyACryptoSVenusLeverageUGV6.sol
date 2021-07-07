//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

contract StrategyACryptoSVenusLeverageUGV6 is Initializable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;
    using MathUpgradeable for uint256;

    address public constant xvs = address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63);
    address public constant venusComptroller = address(0xfD36E2c2a6789Db23113685031d7F16329158384);

    address public constant mdx = address(0x9C65AB58d8d978DB963e63f2bfB7121627e3a739);
    address public constant mdxSwapFarm = address(0x782395303692aBeD877d2737Aa7982345eB44c11);
    address public constant mdexRouter = address(0x7DAe51BD3E3376B8c7c4900E9107f12Be3AF1bA8);

    address public want;
    address public vToken;
    address public uniswapRouter;
    address[] public xvsToWantPath;
    uint256 public targetBorrowLimit;
    uint256 public targetBorrowLimitHysteresis;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public performanceFee;
    uint256 public strategistReward;
    uint256 public withdrawalFee;
    uint256 public harvesterReward;
    uint256 public constant FEE_DENOMINATOR = 10000;

    bool public venusRedemptionFeeActive;

    bool public paused;

    bool public enableHarvestMdxSwapFarm;

    function initialize(address _governance, address _strategist, address _controller, address _want, address _vToken, uint _targetBorrowLimit, uint _targetBorrowLimitHysteresis, address _uniswapRouter, address[] memory _xvsToWantPath, bool _venusRedemptionFeeActive, bool _enableHarvestMdxSwapFarm) public initializer {
        performanceFee = 1450;
        strategistReward = 50;
        withdrawalFee = 10;
        harvesterReward = 30;

        governance = _governance;
        strategist = _strategist;
        controller = _controller;

        want = _want;
        vToken = _vToken;
        targetBorrowLimit = _targetBorrowLimit;
        targetBorrowLimitHysteresis = _targetBorrowLimitHysteresis;
        uniswapRouter = _uniswapRouter;
        xvsToWantPath = _xvsToWantPath;
        venusRedemptionFeeActive = _venusRedemptionFeeActive;
        enableHarvestMdxSwapFarm = _enableHarvestMdxSwapFarm;

        address[] memory _markets = new address[](1);
        _markets[0] = vToken;
        IVenusComptroller(venusComptroller).enterMarkets(_markets);
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoSVenusLeverageUGV6";
    }

    function deposit() public {
      uint256 _want = IERC20Upgradeable(want).balanceOf(address(this));
      if (_want > 0) {
        _supplyWant();
        _rebalance(0);
      }
    }

    function _supplyWant() internal {
      if(paused) return;
      uint256 _want = IERC20Upgradeable(want).balanceOf(address(this));
      IERC20Upgradeable(want).safeApprove(vToken, 0);
      IERC20Upgradeable(want).safeApprove(vToken, _want);
      IVToken(vToken).mint(_want);
    }

    function _claimXvs() internal {
      address[] memory _markets = new address[](1);
      _markets[0] = vToken;
      IVenusComptroller(venusComptroller).claimVenus(address(this), _markets);
    }


    function _rebalance(uint withdrawAmount) internal {
      uint256 _ox = IVToken(vToken).balanceOfUnderlying(address(this));
      if(_ox == 0) return;
      require(withdrawAmount <= _ox, "_rebalance: !withdraw");
      uint256 _x = _ox.sub(withdrawAmount);
      uint256 _y = IVToken(vToken).borrowBalanceCurrent(address(this));
      uint256 _c = _collateralFactor();
      uint256 _L = _c.mul(targetBorrowLimit).div(1e18);
      uint256 _currentL = _divUp(_y,_x == 0 ? 1 : _x);
      uint256 _liquidityAvailable = IVToken(vToken).getCash();

      if(_currentL.add(targetBorrowLimitHysteresis.mul(_c).div(1e18)) < _L) {
        uint256 _dy = _L.mul(_x).div(1e18).sub(_y).mul(1e18).div(uint256(1e18).sub(_L));
        uint256 _max_dy = _ox.mul(_c).div(1e18).sub(_y);

        if(_dy > _max_dy) _dy = _max_dy;
        if(_dy > _liquidityAvailable) _dy = _liquidityAvailable;

        uint256 _borrowCap = IVenusComptroller(venusComptroller).borrowCaps(vToken);
        if (_borrowCap != 0) {
            uint _maxBorrowCap = 0;
            uint _totalBorrows = IVToken(vToken).totalBorrows();
            if(_totalBorrows < _borrowCap.sub(1)) {
              _maxBorrowCap = _borrowCap.sub(1).sub(_totalBorrows);
            }
            if(_dy > _maxBorrowCap) _dy = _maxBorrowCap;
        }

        if(_dy > 0) {
          IVToken(vToken).borrow(_dy);
          _supplyWant();
        }
      } else {
        uint256 _fee = _venusRedemptionFee();
        while(_currentL > _L.add(targetBorrowLimitHysteresis.mul(_c).div(1e18))) {
          uint256 _dy = _divUp(_y.sub(_mulUp(_L,_x)),uint256(1e18).sub(_divUp(_L,uint256(1e18).sub(_fee))));
          if(_dy.add(10) > _y) _dy = _y;
          uint256 _dx = _dy.mul(1e18).div(uint256(1e18).sub(_fee));
          uint256 _max_dx = _ox.sub(_divUp(_y,_c));
          if(_dx > _max_dx) _dx = _max_dx;
          if(_dx > _liquidityAvailable) _dx = _liquidityAvailable;
          require(IVToken(vToken).redeemUnderlying(_dx) == 0, "_rebalance: !redeem");

          _dy = IERC20Upgradeable(want).balanceOf(address(this));
          // if(_dy > _y) _dy = _y;

          _ox = _ox.sub(_dx);
          require(withdrawAmount <= _ox, "_rebalance: !withdraw");
          _x = _ox.sub(withdrawAmount);

          IERC20Upgradeable(want).safeApprove(vToken, 0);
          IERC20Upgradeable(want).safeApprove(vToken, _dy);
          IVToken(vToken).repayBorrow(_dy);
          _y = _y.sub(_dy);

          _currentL = _divUp(_y,_x == 0 ? 1 : _x);
          _liquidityAvailable = IVToken(vToken).getCash();
        }
      }
    }

    function _mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a.mul(b);
        if (product == 0) {
            return 0;
        } else {
            return product.sub(1).div(1e18).add(1);
        }
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        } else {
            return a.mul(1e18).sub(1).div(b).add(1);
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20Upgradeable _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
      require(msg.sender == controller, "!controller");

      uint256 _balance = IERC20Upgradeable(want).balanceOf(address(this));
      if (_balance < _amount) {
          _amount = _withdrawSome(_amount.sub(_balance));
          _amount = _amount.add(_balance);
      }

      uint256 _fee = _amount.mul(withdrawalFee).div(FEE_DENOMINATOR);
      IERC20Upgradeable(want).safeTransfer(IController(controller).rewards(), _fee);
      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20Upgradeable(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
      uint256 _amountToRedeem = _amount.mul(1e18).div(uint256(1e18).sub(_venusRedemptionFee()));
      _rebalance(_amountToRedeem);
      require(IVToken(vToken).redeemUnderlying(_amountToRedeem) == 0, "_withdrawSome: !redeem");
      return _amount;
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
      require(msg.sender == controller || msg.sender == strategist || msg.sender == governance, "!authorized");
      _withdrawAll();

      balance = IERC20Upgradeable(want).balanceOf(address(this));

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20Upgradeable(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
      targetBorrowLimit = 0;
      targetBorrowLimitHysteresis = 0;
      _rebalance(0);
      require(IVToken(vToken).redeem(IVToken(vToken).balanceOf(address(this))) == 0, "_withdrawAll: !redeem");      
    }

    function _convertRewardsToWant() internal {
      uint256 _xvs = IERC20Upgradeable(xvs).balanceOf(address(this));
      if(_xvs > 0) {
        IERC20Upgradeable(xvs).safeApprove(uniswapRouter, 0);
        IERC20Upgradeable(xvs).safeApprove(uniswapRouter, _xvs);

        IUniswapRouter(uniswapRouter).swapExactTokensForTokens(_xvs, uint256(0), xvsToWantPath, address(this), now.add(1800));
      }
    }

    function _harvestMdxSwapFarm() internal {
      IMdxSwapFarm(mdxSwapFarm).takerWithdraw(); //harvest mdx from swap farm
      uint256 _mdx = IERC20Upgradeable(mdx).balanceOf(address(this));
      if(_mdx > 0) {
        IERC20Upgradeable(mdx).safeApprove(mdexRouter, 0);
        IERC20Upgradeable(mdx).safeApprove(mdexRouter, _mdx);

        address[] memory path = new address[](3);
        path[0] = mdx;
        path[1] = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); //busd
        path[2] = xvs;

        IUniswapRouter(mdexRouter).swapExactTokensForTokens(_mdx, uint256(0), path, address(this), now.add(1800));
      }
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    function balanceOfStakedWant() public view returns (uint256) {
      return IVToken(vToken).balanceOf(address(this)).mul(IVToken(vToken).exchangeRateStored()).div(1e18)
        .mul(uint256(1e18).sub(_venusRedemptionFee())).div(1e18)
        .sub(IVToken(vToken).borrowBalanceStored(address(this)));
    }

    function balanceOfStakedWantCurrent() public returns (uint256) {
      return IVToken(vToken).balanceOfUnderlying(address(this))
        .mul(uint256(1e18).sub(_venusRedemptionFee())).div(1e18)
        .sub(IVToken(vToken).borrowBalanceCurrent(address(this)));
    }

    function borrowLimit() public returns (uint256) {
      return IVToken(vToken).borrowBalanceCurrent(address(this))
        .mul(1e18).div(IVToken(vToken).balanceOfUnderlying(address(this)).mul(_collateralFactor()).div(1e18));
    }

    function _collateralFactor() internal view returns (uint256) {
      (,uint256 _cf,) = IVenusComptroller(venusComptroller).markets(vToken);
      return _cf;
    }

    function _venusRedemptionFee() internal view returns (uint256) {
      if(!venusRedemptionFeeActive) return 0;
      return venusRedemptionFeeActive ? IVenusComptroller(venusComptroller).treasuryPercent() : 0;
    }

    function harvest() public returns (uint harvesterRewarded) {
      require(msg.sender == tx.origin, "not eoa");

      uint _xvs = IERC20Upgradeable(xvs).balanceOf(address(this));
      if(enableHarvestMdxSwapFarm) _harvestMdxSwapFarm();
      _claimXvs();
      _xvs = IERC20Upgradeable(xvs).balanceOf(address(this)).sub(_xvs); 

      uint256 _harvesterReward;
      if (_xvs > 0) {
        uint256 _fee = _xvs.mul(performanceFee).div(FEE_DENOMINATOR);
        uint256 _reward = _xvs.mul(strategistReward).div(FEE_DENOMINATOR);
        _harvesterReward = _xvs.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20Upgradeable(xvs).safeTransfer(IController(controller).rewards(), _fee);
        IERC20Upgradeable(xvs).safeTransfer(strategist, _reward);
        IERC20Upgradeable(xvs).safeTransfer(msg.sender, _harvesterReward);
      }

      if(want != xvs) _convertRewardsToWant();
      _supplyWant();
      _rebalance(0);

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
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        performanceFee = _performanceFee;
    }

    function setStrategistReward(uint256 _strategistReward) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        strategistReward = _strategistReward;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!authorized");
        withdrawalFee = _withdrawalFee;
    }

    function setHarvesterReward(uint256 _harvesterReward) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        harvesterReward = _harvesterReward;
    }

    function setTargetBorrowLimit(uint256 _targetBorrowLimit, uint256 _targetBorrowLimitHysteresis) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        targetBorrowLimit = _targetBorrowLimit;
        targetBorrowLimitHysteresis = _targetBorrowLimitHysteresis;
    }

    function setUniswapRouter(address _uniswapRouter, address[] memory _xvsToWantPath) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        uniswapRouter = _uniswapRouter;
        xvsToWantPath = _xvsToWantPath;
    }

    function setVenusRedemptionFeeActive(bool _venusRedemptionFeeActive) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        venusRedemptionFeeActive = _venusRedemptionFeeActive;
    }

    function setEnableHarvestMdxSwapFarm(bool _enableHarvestMdxSwapFarm) external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        enableHarvestMdxSwapFarm = _enableHarvestMdxSwapFarm;
    }

    function pause() external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        _withdrawAll();
        paused = true;
    }

    function unpause() external {
        require(msg.sender == strategist || msg.sender == governance, "!authorized");
        paused = false;
    }

    //In case anything goes wrong - Venus contracts are upgradeable and we have no guarantees how they might change.
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
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        return returnData;
    }
}

interface IController {
    function withdraw(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function earn(address, uint256) external;
    function want(address) external view returns (address);
    function rewards() external view returns (address);
    function vaults(address) external view returns (address);
    function strategies(address) external view returns (address);
}

interface IUniswapRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IVenusComptroller {
  function _addVenusMarkets ( address[] calldata vTokens ) external;
  function _become ( address unitroller ) external;
  function _borrowGuardianPaused (  ) external view returns ( bool );
  function _dropVenusMarket ( address vToken ) external;
  function _mintGuardianPaused (  ) external view returns ( bool );
  function _setCloseFactor ( uint256 newCloseFactorMantissa ) external returns ( uint256 );
  function _setCollateralFactor ( address vToken, uint256 newCollateralFactorMantissa ) external returns ( uint256 );
  function _setLiquidationIncentive ( uint256 newLiquidationIncentiveMantissa ) external returns ( uint256 );
  function _setMaxAssets ( uint256 newMaxAssets ) external returns ( uint256 );
  function _setPauseGuardian ( address newPauseGuardian ) external returns ( uint256 );
  function _setPriceOracle ( address newOracle ) external returns ( uint256 );
  function _setProtocolPaused ( bool state ) external returns ( bool );
  function _setVAIController ( address vaiController_ ) external returns ( uint256 );
  function _setVAIMintRate ( uint256 newVAIMintRate ) external returns ( uint256 );
  function _setVenusRate ( uint256 venusRate_ ) external;
  function _supportMarket ( address vToken ) external returns ( uint256 );
  function accountAssets ( address, uint256 ) external view returns ( address );
  function admin (  ) external view returns ( address );
  function allMarkets ( uint256 ) external view returns ( address );
  function borrowAllowed ( address vToken, address borrower, uint256 borrowAmount ) external returns ( uint256 );
  function borrowGuardianPaused ( address ) external view returns ( bool );
  function borrowVerify ( address vToken, address borrower, uint256 borrowAmount ) external;
  function checkMembership ( address account, address vToken ) external view returns ( bool );
  function claimVenus ( address holder, address[] calldata vTokens ) external;
  function claimVenus ( address holder ) external;
  function claimVenus ( address[] calldata holders, address[] calldata vTokens, bool borrowers, bool suppliers ) external;
  function closeFactorMantissa (  ) external view returns ( uint256 );
  function comptrollerImplementation (  ) external view returns ( address );
  function enterMarkets ( address[] calldata vTokens ) external returns ( uint256[] memory );
  function exitMarket ( address vTokenAddress ) external returns ( uint256 );
  function getAccountLiquidity ( address account ) external view returns ( uint256, uint256, uint256 );
  function getAllMarkets (  ) external view returns ( address[] memory );
  function getAssetsIn ( address account ) external view returns ( address[] memory );
  function getBlockNumber (  ) external view returns ( uint256 );
  function getHypotheticalAccountLiquidity ( address account, address vTokenModify, uint256 redeemTokens, uint256 borrowAmount ) external view returns ( uint256, uint256, uint256 );
  function getMintableVAI ( address minter ) external view returns ( uint256, uint256 );
  function getVAIMintRate (  ) external view returns ( uint256 );
  function getXVSAddress (  ) external view returns ( address );
  function isComptroller (  ) external view returns ( bool );
  function liquidateBorrowAllowed ( address vTokenBorrowed, address vTokenCollateral, address liquidator, address borrower, uint256 repayAmount ) external returns ( uint256 );
  function liquidateBorrowVerify ( address vTokenBorrowed, address vTokenCollateral, address liquidator, address borrower, uint256 actualRepayAmount, uint256 seizeTokens ) external;
  function liquidateCalculateSeizeTokens ( address vTokenBorrowed, address vTokenCollateral, uint256 actualRepayAmount ) external view returns ( uint256, uint256 );
  function liquidationIncentiveMantissa (  ) external view returns ( uint256 );
  function markets ( address ) external view returns ( bool isListed, uint256 collateralFactorMantissa, bool isVenus );
  function maxAssets (  ) external view returns ( uint256 );
  function mintAllowed ( address vToken, address minter, uint256 mintAmount ) external returns ( uint256 );
  function mintGuardianPaused ( address ) external view returns ( bool );
  function mintVAI ( uint256 mintVAIAmount ) external returns ( uint256 );
  function mintVAIGuardianPaused (  ) external view returns ( bool );
  function mintVerify ( address vToken, address minter, uint256 actualMintAmount, uint256 mintTokens ) external;
  function mintedVAIOf ( address owner ) external view returns ( uint256 );
  function mintedVAIs ( address ) external view returns ( uint256 );
  function oracle (  ) external view returns ( address );
  function pauseGuardian (  ) external view returns ( address );
  function pendingAdmin (  ) external view returns ( address );
  function pendingComptrollerImplementation (  ) external view returns ( address );
  function protocolPaused (  ) external view returns ( bool );
  function redeemAllowed ( address vToken, address redeemer, uint256 redeemTokens ) external returns ( uint256 );
  function redeemVerify ( address vToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens ) external;
  function refreshVenusSpeeds (  ) external;
  function repayBorrowAllowed ( address vToken, address payer, address borrower, uint256 repayAmount ) external returns ( uint256 );
  function repayBorrowVerify ( address vToken, address payer, address borrower, uint256 actualRepayAmount, uint256 borrowerIndex ) external;
  function repayVAI ( uint256 repayVAIAmount ) external returns ( uint256 );
  function repayVAIGuardianPaused (  ) external view returns ( bool );
  function seizeAllowed ( address vTokenCollateral, address vTokenBorrowed, address liquidator, address borrower, uint256 seizeTokens ) external returns ( uint256 );
  function seizeGuardianPaused (  ) external view returns ( bool );
  function seizeVerify ( address vTokenCollateral, address vTokenBorrowed, address liquidator, address borrower, uint256 seizeTokens ) external;
  function setMintedVAIOf ( address owner, uint256 amount ) external returns ( uint256 );
  function transferAllowed ( address vToken, address src, address dst, uint256 transferTokens ) external returns ( uint256 );
  function transferGuardianPaused (  ) external view returns ( bool );
  function transferVerify ( address vToken, address src, address dst, uint256 transferTokens ) external;
  function vaiController (  ) external view returns ( address );
  function vaiMintRate (  ) external view returns ( uint256 );
  function venusAccrued ( address ) external view returns ( uint256 );
  // function venusBorrowState ( address ) external view returns ( uint224 index, uint32 block );
  function venusBorrowerIndex ( address, address ) external view returns ( uint256 );
  function venusClaimThreshold (  ) external view returns ( uint256 );
  function venusInitialIndex (  ) external view returns ( uint224 );
  function venusRate (  ) external view returns ( uint256 );
  function venusSpeeds ( address ) external view returns ( uint256 );
  function venusSupplierIndex ( address, address ) external view returns ( uint256 );
  // function venusSupplyState ( address ) external view returns ( uint224 index, uint32 block );

  function borrowCaps ( address ) external view returns ( uint256 );
  function treasuryPercent (  ) external view returns ( uint256 );
}

interface IVToken {
  function _acceptAdmin (  ) external returns ( uint256 );
  function _addReserves ( uint256 addAmount ) external returns ( uint256 );
  function _reduceReserves ( uint256 reduceAmount ) external returns ( uint256 );
  function _setComptroller ( address newComptroller ) external returns ( uint256 );
  function _setImplementation ( address implementation_, bool allowResign, bytes calldata becomeImplementationData ) external;
  function _setInterestRateModel ( address newInterestRateModel ) external returns ( uint256 );
  function _setPendingAdmin ( address newPendingAdmin ) external returns ( uint256 );
  function _setReserveFactor ( uint256 newReserveFactorMantissa ) external returns ( uint256 );
  function accrualBlockNumber (  ) external view returns ( uint256 );
  function accrueInterest (  ) external returns ( uint256 );
  function admin (  ) external view returns ( address );
  function allowance ( address owner, address spender ) external view returns ( uint256 );
  function approve ( address spender, uint256 amount ) external returns ( bool );
  function balanceOf ( address owner ) external view returns ( uint256 );
  function balanceOfUnderlying ( address owner ) external returns ( uint256 );
  function borrow ( uint256 borrowAmount ) external returns ( uint256 );
  function borrowBalanceCurrent ( address account ) external returns ( uint256 );
  function borrowBalanceStored ( address account ) external view returns ( uint256 );
  function borrowIndex (  ) external view returns ( uint256 );
  function borrowRatePerBlock (  ) external view returns ( uint256 );
  function comptroller (  ) external view returns ( address );
  function decimals (  ) external view returns ( uint8 );
  function delegateToImplementation ( bytes calldata data ) external returns ( bytes memory );
  function delegateToViewImplementation ( bytes calldata data ) external view returns ( bytes memory );
  function exchangeRateCurrent (  ) external returns ( uint256 );
  function exchangeRateStored (  ) external view returns ( uint256 );
  function getAccountSnapshot ( address account ) external view returns ( uint256, uint256, uint256, uint256 );
  function getCash (  ) external view returns ( uint256 );
  function implementation (  ) external view returns ( address );
  function interestRateModel (  ) external view returns ( address );
  function isVToken (  ) external view returns ( bool );
  function liquidateBorrow ( address borrower, uint256 repayAmount, address vTokenCollateral ) external returns ( uint256 );
  function mint ( uint256 mintAmount ) external returns ( uint256 );
  function name (  ) external view returns ( string memory );
  function pendingAdmin (  ) external view returns ( address );
  function redeem ( uint256 redeemTokens ) external returns ( uint256 );
  function redeemUnderlying ( uint256 redeemAmount ) external returns ( uint256 );
  function repayBorrow ( uint256 repayAmount ) external returns ( uint256 );
  function repayBorrowBehalf ( address borrower, uint256 repayAmount ) external returns ( uint256 );
  function reserveFactorMantissa (  ) external view returns ( uint256 );
  function seize ( address liquidator, address borrower, uint256 seizeTokens ) external returns ( uint256 );
  function supplyRatePerBlock (  ) external view returns ( uint256 );
  function symbol (  ) external view returns ( string memory );
  function totalBorrows (  ) external view returns ( uint256 );
  function totalBorrowsCurrent (  ) external returns ( uint256 );
  function totalReserves (  ) external view returns ( uint256 );
  function totalSupply (  ) external view returns ( uint256 );
  function transfer ( address dst, uint256 amount ) external returns ( bool );
  function transferFrom ( address src, address dst, uint256 amount ) external returns ( bool );
  function underlying (  ) external view returns ( address );
}

interface IMdxSwapFarm {
  // function addPair ( uint256 _allocPoint, address _pair, bool _withUpdate ) external;
  // function addWhitelist ( address _addToken ) external returns ( bool );
  // function delWhitelist ( address _delToken ) external returns ( bool );
  // function factory (  ) external view returns ( address );
  // function getMdxReward ( uint256 _lastRewardBlock ) external view returns ( uint256 );
  // function getPoolInfo ( uint256 _pid ) external view returns ( address, address, uint256, uint256, uint256, uint256 );
  // function getQuantity ( address outputToken, uint256 outputAmount, address anchorToken ) external view returns ( uint256 );
  // function getUserReward ( uint256 _pid ) external view returns ( uint256, uint256 );
  // function getWhitelist ( uint256 _index ) external view returns ( address );
  // function getWhitelistLength (  ) external view returns ( uint256 );
  // function halvingPeriod (  ) external view returns ( uint256 );
  // function isOwner ( address account ) external view returns ( bool );
  // function isWhitelist ( address _token ) external view returns ( bool );
  // function massMintPools (  ) external;
  // function mdx (  ) external view returns ( address );
  // function mdxPerBlock (  ) external view returns ( uint256 );
  // function mint ( uint256 _pid ) external returns ( bool );
  // function oracle (  ) external view returns ( address );
  // function owner (  ) external view returns ( address );
  // function pairOfPid ( address ) external view returns ( uint256 );
  // function phase ( uint256 blockNumber ) external view returns ( uint256 );
  // function phase (  ) external view returns ( uint256 );
  // function poolInfo ( uint256 ) external view returns ( address pair, uint256 quantity, uint256 totalQuantity, uint256 allocPoint, uint256 allocMdxAmount, uint256 lastRewardBlock );
  // function poolLength (  ) external view returns ( uint256 );
  // function renounceOwnership (  ) external;
  // function reward (  ) external view returns ( uint256 );
  // function reward ( uint256 blockNumber ) external view returns ( uint256 );
  // function router (  ) external view returns ( address );
  // function setHalvingPeriod ( uint256 _block ) external;
  // function setMdxPerBlock ( uint256 _newPerBlock ) external;
  // function setOracle ( address _oracle ) external;
  // function setPair ( uint256 _pid, uint256 _allocPoint, bool _withUpdate ) external;
  // function setRouter ( address newRouter ) external;
  // function startBlock (  ) external view returns ( uint256 );
  // function swap ( address account, address input, address output, uint256 amount ) external returns ( bool );
  function takerWithdraw (  ) external;
  // function targetToken (  ) external view returns ( address );
  // function totalAllocPoint (  ) external view returns ( uint256 );
  // function transferOwnership ( address newOwner ) external;
  // function userInfo ( uint256, address ) external view returns ( uint256 quantity, uint256 blockNumber );
}