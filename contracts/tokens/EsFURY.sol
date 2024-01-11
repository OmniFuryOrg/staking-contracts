// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../tokens/MintableBaseToken.sol";

contract EsFURY is MintableBaseToken {
    constructor() MintableBaseToken("Escrowed FURY", "esFURY", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "esFURY";
    }
}
