// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StealthAddressRegistry} from "../src/StealthAddressRegistry.sol";
import {SlashablePromiseVault} from "../src/SlashablePromiseVault.sol";
import {ConditionalTokenDrop} from "../src/ConditionalTokenDrop.sol";
import {TimeCapsule} from "../src/TimeCapsule.sol";
import {AddressTaggingMarket} from "../src/AddressTaggingMarket.sol";
import {GroupBountyPool} from "../src/GroupBountyPool.sol";
import {AtomicSwapHTLC} from "../src/AtomicSwapHTLC.sol";

/// @notice Production mainnet deploy: 7 on-chain primitives in one broadcast.
contract MainnetDeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("THRYXTREASURY_PRIVATE_KEY");
        address treasury = vm.addr(pk);

        require(block.chainid == 8453, "Base mainnet (chainId 8453) only");

        console2.log("Treasury:", treasury);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        // 1. Stealth address registry (EIP-5564 / EIP-6538)
        StealthAddressRegistry stealth = new StealthAddressRegistry(
            treasury,
            0.0001 ether,    // registerFee
            0.001 ether,     // max registerFee (immutable cap)
            0.00001 ether,   // announceFee
            0.0001 ether     // max announceFee (immutable cap)
        );
        console2.log("StealthAddressRegistry: ", address(stealth));

        // 2. Slashable promise vault (StickK on-chain)
        SlashablePromiseVault vault = new SlashablePromiseVault(
            treasury,
            100,   // successFeeBps (1%)
            200,   // slashFeeBps (2%)
            50,    // slashBountyBps (0.5%)
            1000   // maxFeeBps (10% hard cap)
        );
        console2.log("SlashablePromiseVault:  ", address(vault));

        // 3. Conditional token drop (merkle airdrop with trigger)
        ConditionalTokenDrop drop = new ConditionalTokenDrop(
            treasury,
            0.0001 ether,  // setupFee
            0.001 ether    // max setupFee (immutable cap)
        );
        console2.log("ConditionalTokenDrop:   ", address(drop));

        // 4. Time capsule (ciphertext store + reveal at unlock)
        TimeCapsule capsule = new TimeCapsule(
            treasury,
            1_000_000_000_000,        // 0.000001 ETH per byte (~$0.0035/KB at $3.5k ETH)
            1_000_000_000_000_000     // 1000x cap so treasury can adjust but not gouge
        );
        console2.log("TimeCapsule:            ", address(capsule));

        // 5. Address tagging market (stake-weighted attestations)
        AddressTaggingMarket tagging = new AddressTaggingMarket(
            treasury,
            0.0001 ether,  // minStakeWei
            7 days,        // challengeWindow
            100,           // attestFeeBps (1%)
            2000,          // slashTreasuryShareBps (20% of slashed stake)
            3000           // maxFeeBps (30% hard cap)
        );
        console2.log("AddressTaggingMarket:   ", address(tagging));

        // 6. Group bounty pool (k-of-n dead-man)
        GroupBountyPool group = new GroupBountyPool(
            treasury,
            100,   // registerFeeBps (1%)
            50,    // triggerBountyBps (0.5%)
            50,    // triggerFeeBps (0.5%)
            1000   // maxFeeBps (10% hard cap on each knob)
        );
        console2.log("GroupBountyPool:        ", address(group));

        // 7. Atomic swap HTLC (same-chain trustless P2P swap)
        AtomicSwapHTLC swap = new AtomicSwapHTLC(
            treasury,
            50,    // swapFeeBps (0.5%)
            500    // maxSwapFeeBps (5% hard cap)
        );
        console2.log("AtomicSwapHTLC:         ", address(swap));

        vm.stopBroadcast();
    }
}
