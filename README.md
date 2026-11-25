# Commercial Vehicle Fleets — RWA Protocol

> **Status:** Work in Progress — Full documentation, deployment scripts, and audit specs coming soon.

A modular Solidity smart contract suite for tokenizing commercial vehicle fleets, automating financial waterfalls, and enforcing on-chain governance and auditability on **DotOne Chain (ID: 505)** within the **Aervynx** ecosystem.

## Core Modules

- **`VehicleRWARegistry.sol`** — Fleet SPV registration, ERC-20 ownership units, and compliance whitelisting.
- **`VehicleProfitPool.sol`** — Automated OPEX/reserve deductions and pro-rata investor yield distribution.
- **`MaintenanceAndInsuranceVault.sol`** — Escrow vault with rolling monthly cap, multi-sig approval, and 24h timelock.
- **`VehicleReportVerifier.sol`** — EIP-712 multi-oracle signature verification for financial period settlement.
- **`TelematicsOracleSync.sol`** — IoT mileage/health tracking with dynamic maintenance reserve ratios.
- **`EmergencyGovernanceHook.sol`** — Weighted token-holder voting for total-loss and operator replacement.
- **`AutomatedTaxAndAuditLedger.sol`** — Append-only on-chain depreciation, tax calculation, and audit ledger.

## Tech Stack

- **Solidity** `^0.8.20` | **OpenZeppelin** (UUPS & AccessControl) | **Foundry / Remix**
- **License:** MIT | **Author:** Parsa Abolhasani Rad
