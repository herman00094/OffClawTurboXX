// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OffClawTurboXX
/// @notice Turbo V2 clawbot: document queue, sheet cell ledger, inbox registry with batch ops, pause, fees and tags.
/// @dev Governor, queue keeper, sheet oracle, inbox vault and fee recipient set at deploy. All immutable.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

contract OffClawTurboXX is ReentrancyGuard {

    event TurboDocEnqueued(bytes32 indexed docId, address indexed by, uint8 docType, uint256 epoch, bytes32 payloadHash);
    event TurboDocBatchEnqueued(bytes32[] docIds, address indexed by, uint256 epoch);
    event TurboDocProcessed(bytes32 indexed docId, address indexed by, uint256 atBlock);
    event TurboDocDeprecated(bytes32 indexed docId, address indexed by, uint256 atBlock);
    event TurboDocUpdated(bytes32 indexed docId, bytes32 newPayloadHash, uint256 atBlock);
    event TurboCellLogged(bytes32 indexed cellRef, uint8 sheetApp, uint256 atBlock, bytes32 valueHash);
    event TurboCellBatchLogged(bytes32[] cellRefs, address indexed by, uint256 count);
    event TurboSlotReserved(bytes32 indexed slotId, address indexed by, uint8 inboxType, uint256 atBlock);
    event TurboSlotBatchReserved(bytes32[] slotIds, address indexed by, uint256 count);
    event TurboEpochBumped(uint256 prevEpoch, uint256 newEpoch, uint256 atBlock);
    event TurboTreasuryTopped(uint256 amount, address indexed from, uint256 newBalance);
    event TurboPaused(address indexed by, uint256 atBlock);
    event TurboUnpaused(address indexed by, uint256 atBlock);
    event TurboFeesWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event TurboTreasuryWithdrawn(address indexed to, uint256 amount, uint256 atBlock);

    error OffClawTurbo_QueueFull();
    error OffClawTurbo_NotGovernor();
    error OffClawTurbo_NotQueueKeeper();
    error OffClawTurbo_NotSheetOracle();
    error OffClawTurbo_NotInboxVault();
    error OffClawTurbo_EpochWindowNotReached();
    error OffClawTurbo_DuplicateDocId();
    error OffClawTurbo_DocNotFound();
    error OffClawTurbo_ZeroDocId();
    error OffClawTurbo_AlreadyProcessed();
    error OffClawTurbo_CellSlotFull();
    error OffClawTurbo_InboxSlotFull();
    error OffClawTurbo_Paused();
    error OffClawTurbo_BatchTooLarge();
    error OffClawTurbo_ZeroLength();
    error OffClawTurbo_WithdrawZero();
    error OffClawTurbo_DocDeprecated();
    error OffClawTurbo_ArrayLengthMismatch();

    uint256 public constant TURBO_DOC_CAP_PER_EPOCH = 512;
    uint256 public constant TURBO_CELL_SLOTS = 128;
    uint256 public constant TURBO_INBOX_SLOTS = 64;
    uint256 public constant TURBO_EPOCH_BLOCKS = 96;
    uint256 public constant MAX_TURBO_EPOCHS = 4096;
    uint256 public constant MAX_BATCH_DOCS = 32;
    uint256 public constant MAX_BATCH_CELLS = 24;
    uint256 public constant MAX_BATCH_SLOTS = 16;
    uint256 public constant MAX_DOC_TYPE = 15;
    uint256 public constant MAX_TAGS = 4;
    uint256 public constant FEE_BASIS_POINTS = 30;
    uint256 public constant BASIS_DENOM = 10_000;
    bytes32 public constant TURBO_DOMAIN = bytes32(uint256(0x3f6a8c1E5b9D2f4A7c0e3B6d9F2a5C8e1B4d7F0a3c6E9b2));

    address public immutable turboGovernor;
    address public immutable turboQueueKeeper;
    address public immutable turboSheetOracle;
    address public immutable turboInboxVault;
    address public immutable turboFeeRecipient;
    uint256 public immutable genesisBlock;
    bytes32 public immutable turboSeed;

    bool public paused;
    uint256 public currentEpoch;
    uint256 public totalDocsQueued;
    uint256 public totalCellsLogged;
    uint256 public totalSlotsReserved;
    uint256 public turboBalance;
    uint256 public accumulatedFees;

    mapping(uint256 => uint256) private _docsInEpoch;
    mapping(bytes32 => TurboDoc) private _docs;
    bytes32[] private _docIdList;
    mapping(uint256 => TurboCellSlot) private _cellSlots;
    bytes32[] private _cellRefList;
    mapping(uint256 => TurboInboxSlot) private _inboxSlots;
    bytes32[] private _inboxIdList;
    mapping(uint256 => bool) private _epochAdvanced;

    struct TurboDoc {
        bytes32 docId;
        address enqueuedBy;
        uint8 docType;
        uint256 queueEpoch;
        uint256 enqueuedAtBlock;
        uint256 updatedAtBlock;
        bytes32 payloadHash;
        bytes32[MAX_TAGS] tags;
        bool processed;
        bool deprecated;
    }

    struct TurboCellSlot {
        bytes32 cellRef;
        uint8 sheetApp;
        uint256 loggedAtBlock;
        bytes32 valueHash;
        bool exists;
    }

    struct TurboInboxSlot {
        bytes32 slotId;
        address reservedBy;
        uint8 inboxType;
        uint256 reservedAtBlock;
        bool exists;
    }

    struct TurboStats {
        uint256 totalDocs;
        uint256 totalCells;
        uint256 totalInbox;
        uint256 currentEpoch;
        uint256 balance;
        uint256 fees;
        bool isPaused;
    }

    struct EpochInfo {
        uint256 epoch;
        uint256 docsInEpoch;
        bool advanced;
        uint256 blockStart;
        uint256 blockEnd;
    }

    modifier onlyTurboGovernor() {
        if (msg.sender != turboGovernor) revert OffClawTurbo_NotGovernor();
        _;
    }
    modifier onlyQueueKeeper() {
        if (msg.sender != turboQueueKeeper) revert OffClawTurbo_NotQueueKeeper();
        _;
    }
    modifier onlySheetOracle() {
        if (msg.sender != turboSheetOracle) revert OffClawTurbo_NotSheetOracle();
        _;
    }
    modifier onlyInboxVault() {
        if (msg.sender != turboInboxVault) revert OffClawTurbo_NotInboxVault();
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert OffClawTurbo_Paused();
        _;
    }

    constructor() {
        turboGovernor = address(0xBc3d7F1a9E4c6A0b2D5f8C1e4A7b0D3f6);
        turboQueueKeeper = address(0xD4e8F0a2B5c7D9e1F3a6B8c0D2e5F7a9);
