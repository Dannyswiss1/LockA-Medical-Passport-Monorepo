# LockA Medical Passport

**Summary**

LockA Medical Passport is a decentralized digital health identity and medical records platform designed to give patients direct control over their healthcare data. The product is inspired by the concept of a school locker: a safe, personal space where a student keeps important items. LockA applies that same idea to healthcare by creating a secure digital locker for medical records, where the patient decides who can access their health information, for what purpose, and for how long.

### 1. Executive Summary

LockA Medical Passport is a patient-controlled digital health identity and record access framework for secure, portable, and privacy-preserving healthcare data management. In this Base-based implementation, patients own and manage their passport identity on-chain, providers can request access to approved records, and verifiable cryptographic proofs can be attached to support identity, eligibility, and credential workflows.

The platform addresses common healthcare problems such as fragmented medical records, repeated diagnostics, weak interoperability, and poor patient control over consent. Rather than storing raw medical data directly on-chain, the system stores hashes, commitments, consent state, and verification outcomes while keeping detailed records in encrypted off-chain storage.

### 2. Problem Statement

Healthcare data is often fragmented across hospitals, clinics, laboratories, pharmacies, and insurance providers. Patients can lose continuity of care when records are scattered, inaccessible, or difficult to verify. This creates delays in treatment, higher costs, and unnecessary exposure of sensitive medical information.

LockA solves this by giving patients a portable digital passport that can be used across providers while preserving privacy and requiring explicit consent for access. In the EVM implementation, this is achieved through smart contracts that manage patient identity, provider verification, permissions, record commitments, and ZK-based verification.

### 3. Product Vision and Objectives

The vision of LockA on Base is to create a trusted healthcare infrastructure layer where patients can control who can access their medical data, under what conditions, and for what duration.

Core objectives:

- Patient ownership: Patients control their passport identity, recovery configuration, and consent lifecycle.
- Provider trust: Verified providers can request and receive access only after passing on-chain validation.
- Privacy by design: Raw records remain off-chain; the chain stores proofs, hashes, and state transitions.
- Interoperability: The solution is designed to work across providers, records, and future integrations.
- Auditability: Every access request, approval, and revocation can be represented through contract state and events.
- Open-source extensibility: The contracts are modular and structured for community review, testing, and upgradeability.

### 4. Core Users and Stakeholders

- Patients: Create a passport, manage access permissions, approve or revoke consent, and control their health identity.
- Hospitals and Clinics: Register as verified providers, request access to approved patient data, and add record proofs.
- Laboratories and Diagnostic Centers: Submit verifiable record commitments for tests and results.
- Pharmacies and Insurance Providers: Validate eligibility, prescriptions, and coverage claims through permissioned workflows.
- Public Health Programs: Use privacy-preserving verification models without exposing full medical records.

### 5. Platform Model

LockA is not a single monolithic app. It is a healthcare data access network composed of:

- Patient-facing interface for passport creation, consent management, and record access.
- Provider dashboard for registration, access requests, and record submission.
- Backend services for encrypted storage, indexing, notifications, and integration workflows.
- Solidity smart contracts for identity, provider verification, permissions, record commitment, and proof verification.

### 6. High-Level Architecture (Base / EVM)

The architecture separates sensitive health data from blockchain verification. Medical records are not stored directly on-chain. Instead, the on-chain layer records:

- Passport identity and status
- Provider registry and verification state
- Consent permissions and expiry
- Record hash commitments and storage references
- ZK verification outcomes and claim status

Sensitive records remain encrypted off-chain and are retrieved only when authorized by the patient and the access rules encoded in the system.

### 7. Technology Stack

| Layer | Implementation in this Repository |
| --- | --- |
| Blockchain | Base (EVM-compatible Layer 2) |
| Smart Contracts | Solidity with OpenZeppelin contracts |
| Identity and Access | PatientPassportRegistry, ProviderRegistry, ConsentAccessManager |
| Record Proofs | MedicalRecordRegistry |
| Privacy Verification | LockAZKVerifier with zkVerify-style proof aggregation |
| Orchestration | LockAOrchestrator |
| ENS Integration | ENSResolverHelper |
| Frontend | React-based web interface |
| Backend | Application services for indexing, storage, and integrations |

### 8. Smart Contract Architecture in This Repository

The current repository is aligned with the following contract responsibilities:

- PatientPassportRegistry: Creates and manages patient passport identities, wallet ownership, recovery addresses, and passport lifecycle state.
- ProviderRegistry: Registers healthcare providers, tracks verification status, and provides provider identity lookups.
- MedicalRecordRegistry: Stores cryptographic proofs of medical records, including encrypted file hashes and storage pointer hashes, without exposing raw data on-chain.
- ConsentAccessManager: Manages patient-provider access requests, approvals, expiry, and revocation.
- LockAZKVerifier: Verifies privacy-preserving claims such as identity validity, eligibility, and credential proofs.
- LockAOrchestrator: Provides composite validation across the registries and acts as a coordination layer for cross-contract checks.
- ENSResolverHelper: Supports human-readable ENS-style identity resolution and integration with the registries.
- HealthcarePaymentToken: Provides an optional token-based utility layer for future billing or incentive workflows.

### 9. Data Storage, Privacy, and Verification

The privacy model is intentionally hybrid:

- Raw medical files are stored off-chain in encrypted form.
- The blockchain stores references, hashes, permissions, and state transitions.
- Access is governed by patient consent and provider verification.
- ZK-style verification logic can be used to prove eligibility or identity without revealing unnecessary data.

This design preserves confidentiality while still creating a verifiable audit trail and tamper-evident record history.

### 10. Key User Flows

1. Patient registers a passport and connects a wallet.
2. Provider registers and is verified by the administrative layer.
3. Provider requests access to a specific category of record.
4. Patient approves, rejects, limits, or revokes the permission.
5. Medical records are added as on-chain commitments with off-chain encrypted storage.
6. ZK claims can be verified to prove identity or eligibility without exposing full records.

### 11. Repository Structure

The repository is organized around the EVM implementation:

- smart-contracts/: Solidity contracts, interfaces, and deployment scripts
- interfaces/: contract interface definitions
- frontend/: web application interface
- backend/: application services and integration layer
- artifacts/: compiled contract artifacts

### 12. MVP Scope

The initial Base-based MVP should demonstrate the core idea of patient-controlled health data access using smart contracts:

- Patient passport creation and ownership
- Provider registration and verification
- Consent request and approval flows
- Record commitment anchoring with off-chain encrypted storage
- Basic ZK claim verification for identity or eligibility
- Cross-contract validation through the orchestrator layer

This MVP focuses on core trust, access control, privacy, and auditability rather than replacing full legacy healthcare systems.

### Deployed Contract Addresses
**PatientPassportRegistry:** `0x4fd6EB270CbF4C430E38f6559DaBA77555a648C7` Manages patient health passport identities

**ProviderRegistry:** `0x0f5D06446D3544dE1fB37090d9Bf58988Afb2c09` Manages healthcare provider registrations

**MedicalRecordRegistry:** `0x825caf2E7a82D33D600dcB5bbFE535F635E28b59` Stores encrypted medical record hashes on-chain

**ConsentAccessManager:** `0xb157945fC9ca17E56299a0280E9a04cEbbdd68Ac` Controls patient consent and provider data access

