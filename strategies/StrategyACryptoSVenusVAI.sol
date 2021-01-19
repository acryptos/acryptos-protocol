pragma solidity ^0.5.17;

import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/IERC20.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/SafeMath.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/math/Math.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/utils/Address.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/SafeERC20.sol";

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
}

interface IVenusVAIVault {
  // function _become ( address vaiVaultProxy ) external;
  // function accXVSPerShare (  ) external view returns ( uint256 );
  // function admin (  ) external view returns ( address );
  // function burnAdmin (  ) external;
  function claim (  ) external;
  function deposit ( uint256 _amount ) external;
  // function getAdmin (  ) external view returns ( address );
  // function pendingAdmin (  ) external view returns ( address );
  // function pendingRewards (  ) external view returns ( uint256 );
  // function pendingVAIVaultImplementation (  ) external view returns ( address );
  // function pendingXVS ( address _user ) external view returns ( uint256 );
  // function setNewAdmin ( address newAdmin ) external;
  // function setVenusInfo ( address _xvs, address _vai ) external;
  // function updatePendingRewards (  ) external;
  function userInfo ( address ) external view returns ( uint256 amount, uint256 rewardDebt );
  // function vai (  ) external view returns ( address );
  // function vaiVaultImplementation (  ) external view returns ( address );
  function withdraw ( uint256 _amount ) external;
  // function xvs (  ) external view returns ( address );
  // function xvsBalance (  ) external view returns ( uint256 );
}

interface IStableSwap {
  // function withdraw_admin_fees() external;
  // function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_amount) external;
  // function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);
  function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);
}



contract StrategyACryptoSVenusVAI {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Math for uint256;

    address public constant xvs = address(0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63);
    address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public constant busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address public constant uniswapRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address public constant ssPool = address(0x191409D5A4EfFe25b0f4240557BA2192D18a191e);
    address public constant venusVAIVault = address(0x0667Eed0a0aAb930af74a3dfeDD263A73994f216);

    address public want;

    address public governance;
    address public controller;
    address public strategist;

    uint256 public performanceFee = 450;
    uint256 public strategistReward = 50;
    uint256 public withdrawalFee = 50;
    uint256 public harvesterReward = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    constructor(address _controller, address _want) public {
        governance = msg.sender;
        strategist = msg.sender;
        controller = _controller;

        want = _want;
    }

    function getName() external pure returns (string memory) {
        return "StrategyACryptoSVenusVAI";
    }

    function deposit() public {
      _supplyWant();
    }

    function _supplyWant() internal {
      uint256 _want = IERC20(want).balanceOf(address(this));
      if (_want > 0) {
        IERC20(want).safeApprove(venusVAIVault, 0);
        IERC20(want).safeApprove(venusVAIVault, _want);
        IVenusVAIVault(venusVAIVault).deposit(_want);
      }
    }

    function _claimXvs() internal {
      IVenusVAIVault(venusVAIVault).claim();
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
      IVenusVAIVault(venusVAIVault).withdraw(_amount);
      return _amount;
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
      require(msg.sender == controller || msg.sender == strategist || msg.sender == governance, "!authorized");
      _withdrawAll();

      balance = IERC20(want).balanceOf(address(this));

      address _vault = IController(controller).vaults(address(want));
      require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
      IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
      IVenusVAIVault(venusVAIVault).withdraw(balanceOfStakedWant());
    }

    function _convertRewardsToWant() internal {
      uint256 _xvs = IERC20(xvs).balanceOf(address(this));
      if(_xvs > 0 ) {
        IERC20(xvs).safeApprove(uniswapRouter, 0);
        IERC20(xvs).safeApprove(uniswapRouter, _xvs);

        address[] memory path = new address[](3);
        path[0] = xvs;
        path[1] = wbnb;
        path[2] = busd;

        IUniswapRouter(uniswapRouter).swapExactTokensForTokens(_xvs, uint256(0), path, address(this), now.add(1800));

        uint256 _busd = IERC20(busd).balanceOf(address(this));
        if(_busd > 0) {
          IERC20(busd).safeApprove(ssPool, 0);
          IERC20(busd).safeApprove(ssPool, _busd);
          IStableSwap(ssPool).exchange_underlying(1, 0, _busd, 0);            
        }
      }
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfStakedWant() public view returns (uint256) {
      (uint256 _amount,) = IVenusVAIVault(venusVAIVault).userInfo(address(this));
      return _amount;
    }

    function harvest() public returns (uint harvesterRewarded) {
      require(msg.sender == tx.origin, "not eoa");

      _claimXvs();

      uint _xvs = IERC20(xvs).balanceOf(address(this)); 
      uint256 _harvesterReward;
      if (_xvs > 0) {
        uint256 _fee = _xvs.mul(performanceFee).div(FEE_DENOMINATOR);
        uint256 _reward = _xvs.mul(strategistReward).div(FEE_DENOMINATOR);
        _harvesterReward = _xvs.mul(harvesterReward).div(FEE_DENOMINATOR);
        IERC20(xvs).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(xvs).safeTransfer(strategist, _reward);
        IERC20(xvs).safeTransfer(msg.sender, _harvesterReward);
      }

      _convertRewardsToWant();
      _supplyWant();

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
        (bool success, bytes memory returnData) = target.call.value(value)(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        return returnData;
    }
}
