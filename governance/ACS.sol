pragma solidity ^0.5.17;

import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/ERC20Mintable.sol";
import "../../openzeppelin-contracts-2.5.1/contracts/token/ERC20/ERC20Detailed.sol";

contract ACS is ERC20Mintable, ERC20Detailed {
  constructor() ERC20Detailed("ACryptoS", "ACS", 18) public {
    _mint(msg.sender, 8_888_888888_888888_888888);
  }
}