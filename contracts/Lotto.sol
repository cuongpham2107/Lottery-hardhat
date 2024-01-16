// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract Lotto is ERC20, ERC20Burnable, Ownable,AccessControl{


    uint256 private initialSupply = 50_000_000_000 * 10**uint256(18);

    bytes32 public  constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address initialOwner) ERC20("Lotto", "LOT") Ownable(initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
        _mint(msg.sender, initialSupply);
    }
    function mint(address to, uint256 amount) public  onlyOwner{
        require(ERC20.totalSupply() + amount <= initialSupply, "Lotto: cap excceded");
        _mint(to, amount);
    }


    function burnFrom(address account, uint256 amount) public  override  {
        if(hasRole(MINTER_ROLE, _msgSender())){
            _burn(account, amount);
        }
        else {
            super.burnFrom(account, amount);
        }
    }
}

