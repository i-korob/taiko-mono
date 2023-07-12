// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 } from "forge-std/console2.sol";
import { Test } from "forge-std/Test.sol";
import { AddressManager } from "../contracts/common/AddressManager.sol";
import { IBridge, Bridge } from "../contracts/bridge/Bridge.sol";
import { BridgeErrors } from "../contracts/bridge/BridgeErrors.sol";
import { NFTVaultParent } from "../contracts/bridge/NFTVaultParent.sol";
import { ERC721Vault } from "../contracts/bridge/erc721/ERC721Vault.sol";
import { LibERC721 } from "../contracts/bridge/erc721/libs/LibERC721.sol";
import { EtherVault } from "../contracts/bridge/EtherVault.sol";
import { LibBridgeStatus } from "../contracts/bridge/libs/LibBridgeStatus.sol";
import { SignalService } from "../contracts/signal/SignalService.sol";
import { ICrossChainSync } from "../contracts/common/ICrossChainSync.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// Template canonical erc721 token
contract TestTokenERC721 is ERC721 {
    string _baseTokenURI;
    uint256 minted;

    constructor(string memory baseURI) ERC721("TT", "TT"){
        setBaseURI(baseURI);
    }
    
    function setBaseURI(string memory baseURI) internal {
        _baseTokenURI = baseURI;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }
    
    function mint(uint256 amount) public {
        for (uint256 i; i < amount; i++) {
            _safeMint(msg.sender, minted + i);
        }
        minted+= amount;
    }
}

// NonNftContract
contract NonNftContract {
    uint256 dummyData;

    constructor(uint256 _dummyData) {
        dummyData = _dummyData;
    }
}

contract BadReceiver {
    receive() external payable {
        revert("can not send to this contract");
    }

    fallback() external payable {
        revert("can not send to this contract");
    }

    function transfer() public pure {
        revert("this fails");
    }
}

contract PrankCrossChainSync is ICrossChainSync {
    bytes32 private _blockHash;
    bytes32 private _signalRoot;

    function setCrossChainBlockHeader(bytes32 blockHash) external {
        _blockHash = blockHash;
    }

    function setCrossChainSignalRoot(bytes32 signalRoot) external {
        _signalRoot = signalRoot;
    }

    function getCrossChainBlockHash(uint256) external view returns (bytes32) {
        return _blockHash;
    }

    function getCrossChainSignalRoot(uint256) external view returns (bytes32) {
        return _signalRoot;
    }
}

contract ERC721VaultTest is Test {
    AddressManager addressManager;
    BadReceiver badReceiver;
    Bridge bridge;
    Bridge destChainBridge;
    ERC721Vault erc721Vault;
    ERC721Vault destChainErc721Vault;
    TestTokenERC721 canonicalToken721;
    EtherVault etherVault;
    SignalService signalService;
    PrankCrossChainSync crossChainSync;
    uint256 destChainId = 19_389;

    address public constant Alice = 0x10020FCb72e27650651B05eD2CEcA493bC807Ba4;

    address public constant Bob = 0x50081b12838240B1bA02b3177153Bca678a86078;

    function setUp() public {
        vm.startPrank(Alice);
        vm.deal(Alice, 100 ether);
        addressManager = new AddressManager();
        addressManager.init();

        bridge = new Bridge();
        bridge.init(address(addressManager));

        destChainBridge = new Bridge();
        destChainBridge.init(address(addressManager));

        signalService = new SignalService();
        signalService.init(address(addressManager));

        etherVault = new EtherVault();
        etherVault.init(address(addressManager));

        erc721Vault = new ERC721Vault();
        erc721Vault.init(address(addressManager));

        destChainErc721Vault = new ERC721Vault();
        destChainErc721Vault.init(address(addressManager));

        crossChainSync = new PrankCrossChainSync();

        addressManager.setAddress(
            block.chainid, "signal_service", address(signalService)
        );

        addressManager.setAddress(
            block.chainid, "bridge", address(bridge)
        );

        addressManager.setAddress(
            destChainId, "bridge", address(destChainBridge)
        );

        addressManager.setAddress(
            block.chainid, "erc721_vault", address(erc721Vault)
        );

        addressManager.setAddress(
            destChainId, "erc721_vault", address(destChainErc721Vault)
        );

        canonicalToken721 = new TestTokenERC721("http://example.host.com/");
        canonicalToken721.mint(10);

        vm.stopPrank();
    }

    function test_sendToken_ERC721()
        public
    {
        vm.prank(Alice,Alice);
        canonicalToken721.approve(address(erc721Vault),1);

        assertEq(canonicalToken721.ownerOf(1), Alice);

        NFTVaultParent.BridgeTransferOp memory sendOpts = NFTVaultParent.BridgeTransferOp(
            destChainId,
            Alice,
            address(canonicalToken721),
            "http://example.host.com/",
            1,
            1,// With ERC721 still need to specify 1
            140000,
            140000,
            Alice,
            ""
        );
        vm.prank(Alice,Alice);
        erc721Vault.sendToken{ value: 140000 }(sendOpts);

        assertEq(ERC721(canonicalToken721).ownerOf(1), address(erc721Vault));
    }

    function test_decode_message_calldata_721()
        public
    {

        NFTVaultParent.CanonicalNFT memory canonicalToken = NFTVaultParent.CanonicalNFT({
            srcChainId: 31337,
            tokenAddr: 0x579FBFF1A9b1502688169DA761DcF262b73BB64A,
            symbol: "TT",
            name: "TT",
            uri: "http://example.host.com/"
        });

        bytes memory dataToDecode =  abi.encodeWithSelector(
                0x2c349adf,
                canonicalToken,
                Alice,
                Alice,
                1
        );

        NFTVaultParent.CanonicalNFT memory nftRetVal;
        address ownerRetVal;
        uint256 tokenIdRetVal;
        (nftRetVal, ownerRetVal,,tokenIdRetVal) = 
            LibERC721.decodeTokenData(dataToDecode);

        assertEq(Alice, ownerRetVal);
        assertEq(1, tokenIdRetVal);
        assertEq(31337, nftRetVal.srcChainId);
        assertEq(0x579FBFF1A9b1502688169DA761DcF262b73BB64A, nftRetVal.tokenAddr);
        assertEq("TT", nftRetVal.symbol);
        assertEq("TT", nftRetVal.name);
        assertEq("http://example.host.com/", nftRetVal.uri);
    }
}
