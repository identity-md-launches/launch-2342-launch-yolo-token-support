// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {OracleAttestation} from "../OracleAttestation.sol";
import {ParamsRegistry} from "../ParamsRegistry.sol";

/// @title AttestationChecker
/// @notice Stateless helper of TaskVault: verifies a swarm answer (EIP-712 attestation signed by the IMD oracle) for
///         a consumer contract. The attester set is the registry's (global: key rotation reaches old tasks too).
contract AttestationChecker {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    ParamsRegistry public immutable registry;

    constructor(address registry_) {
        registry = ParamsRegistry(registry_);
    }

    /// @notice EIP-712 digest of an attestation for `consumer`: domain ("IdentityMD Oracle", "2", chainid, consumer).
    function digest(address consumer, OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(OracleAttestation.DOMAIN_NAME)),
                keccak256(bytes(OracleAttestation.DOMAIN_VERSION)),
                block.chainid,
                consumer
            )
        );
        return MessageHashUtils.toTypedDataHash(domain, OracleAttestation.hashStruct(a));
    }

    /// @notice The message `chainId` is the evidence chain chosen in bodyFields and is not checked; the consumer chain
    ///         and contract are bound by the EIP-712 domain. An answer of a smaller panel or quorum than the one
    ///         ordered (`minPanelSize` / `minQuorum`, the same numbers as in bodyFields) is not the swarm's verdict.
    ///         An attestation past its signed `expiresAt` is not accepted (0 = no expiry).
    /// @return code 0 ok, 2 answer type / encoding, 4 panel / quorum, 5 signer not in the attester set, 6 expired
    // slither-disable-next-line unused-return
    function check(
        address consumer,
        uint16 minPanelSize,
        uint16 minQuorum,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external view returns (uint8) {
        if (a.answerType != OracleAttestation.ANSWER_BOOL || a.answer.length != 32) return 2;
        if (uint256(bytes32(a.answer)) > 1) return 2;
        if (a.panelSize < minPanelSize || a.quorum < minQuorum || a.quorum > a.panelSize) return 4;
        if (a.agreed < a.quorum || a.agreed > a.panelSize) return 4;
        if (a.expiresAt != 0 && a.expiresAt < block.timestamp) return 6;
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest(consumer, a), signature);
        if (err != ECDSA.RecoverError.NoError || !registry.isAttester(signer)) return 5;
        return 0;
    }
}
