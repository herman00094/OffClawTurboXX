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
        turboSheetOracle = address(0xE5f9A1b3C6d8E0F2a5B7c9D1e4A6b8C0);
        turboInboxVault = address(0xF6a0B2c4D7e9F1a3B5c8D0e2F4a6B8);
        turboFeeRecipient = address(0x0A1c3e5F8b0D2f4A6c9E1a3B5d7F0b2);
        genesisBlock = block.number;
        turboSeed = keccak256(abi.encodePacked(block.number, block.prevrandao, block.chainid));
        currentEpoch = 0;
        totalDocsQueued = 0;
        totalCellsLogged = 0;
        totalSlotsReserved = 0;
        turboBalance = 0;
        accumulatedFees = 0;
        paused = false;
    }

    function setPaused(bool _paused) external onlyTurboGovernor {
        paused = _paused;
        if (_paused) emit TurboPaused(msg.sender, block.number);
        else emit TurboUnpaused(msg.sender, block.number);
    }

    function _enqueueOne(bytes32 docId, uint8 docType, bytes32 payloadHash, bytes32[MAX_TAGS] memory tags) internal {
        if (docId == bytes32(0)) revert OffClawTurbo_ZeroDocId();
        if (_docs[docId].enqueuedAtBlock != 0) revert OffClawTurbo_DuplicateDocId();
        if (_docsInEpoch[currentEpoch] >= TURBO_DOC_CAP_PER_EPOCH) revert OffClawTurbo_QueueFull();
        if (docType > MAX_DOC_TYPE) docType = 0;
        _docsInEpoch[currentEpoch] += 1;
        totalDocsQueued += 1;
        _docs[docId] = TurboDoc({
            docId: docId,
            enqueuedBy: msg.sender,
            docType: docType,
            queueEpoch: currentEpoch,
            enqueuedAtBlock: block.number,
            updatedAtBlock: block.number,
            payloadHash: payloadHash,
            tags: tags,
            processed: false,
            deprecated: false
        });
        _docIdList.push(docId);
        emit TurboDocEnqueued(docId, msg.sender, docType, currentEpoch, payloadHash);
    }

    function enqueueDoc(bytes32 docId, uint8 docType, bytes32 payloadHash)
        external
        onlyTurboGovernor
        whenNotPaused
        nonReentrant
    {
        bytes32[MAX_TAGS] memory t;
        _enqueueOne(docId, docType, payloadHash, t);
    }

    function enqueueDocWithTags(bytes32 docId, uint8 docType, bytes32 payloadHash, bytes32[4] calldata tags)
        external
        onlyTurboGovernor
        whenNotPaused
        nonReentrant
    {
        bytes32[MAX_TAGS] memory t;
        for (uint256 i = 0; i < MAX_TAGS; i++) t[i] = tags[i];
        _enqueueOne(docId, docType, payloadHash, t);
    }

    function enqueueDocBatch(bytes32[] calldata docIds, uint8[] calldata docTypes, bytes32[] calldata payloadHashes)
        external
        onlyTurboGovernor
        whenNotPaused
        nonReentrant
    {
        if (docIds.length == 0) revert OffClawTurbo_ZeroLength();
        if (docIds.length > MAX_BATCH_DOCS) revert OffClawTurbo_BatchTooLarge();
        if (docIds.length != docTypes.length || docIds.length != payloadHashes.length) revert OffClawTurbo_ArrayLengthMismatch();
        bytes32[MAX_TAGS] memory t;
        for (uint256 i = 0; i < docIds.length; i++) _enqueueOne(docIds[i], docTypes[i], payloadHashes[i], t);
        emit TurboDocBatchEnqueued(docIds, msg.sender, currentEpoch);
    }

    function markDocProcessed(bytes32 docId) external onlyQueueKeeper nonReentrant {
        if (docId == bytes32(0)) revert OffClawTurbo_ZeroDocId();
        TurboDoc storage d = _docs[docId];
        if (d.enqueuedAtBlock == 0) revert OffClawTurbo_DocNotFound();
        if (d.processed) revert OffClawTurbo_AlreadyProcessed();
        d.processed = true;
        emit TurboDocProcessed(docId, msg.sender, block.number);
    }

    function markDocDeprecated(bytes32 docId) external onlyTurboGovernor whenNotPaused nonReentrant {
        if (docId == bytes32(0)) revert OffClawTurbo_ZeroDocId();
        TurboDoc storage d = _docs[docId];
        if (d.enqueuedAtBlock == 0) revert OffClawTurbo_DocNotFound();
        d.deprecated = true;
        emit TurboDocDeprecated(docId, msg.sender, block.number);
    }

    function updateDocPayload(bytes32 docId, bytes32 newPayloadHash) external onlyTurboGovernor whenNotPaused nonReentrant {
        if (docId == bytes32(0)) revert OffClawTurbo_ZeroDocId();
        TurboDoc storage d = _docs[docId];
        if (d.enqueuedAtBlock == 0) revert OffClawTurbo_DocNotFound();
        if (d.deprecated) revert OffClawTurbo_DocDeprecated();
        d.payloadHash = newPayloadHash;
        d.updatedAtBlock = block.number;
        emit TurboDocUpdated(docId, newPayloadHash, block.number);
    }

    function _logCellOne(bytes32 cellRef, uint8 sheetApp, bytes32 valueHash) internal {
        if (sheetApp >= TURBO_CELL_SLOTS) sheetApp = 0;
        uint256 slotIndex = uint256(keccak256(abi.encodePacked(cellRef))) % TURBO_CELL_SLOTS;
        while (_cellSlots[slotIndex].exists) slotIndex = (slotIndex + 1) % TURBO_CELL_SLOTS;
        _cellSlots[slotIndex] = TurboCellSlot({
            cellRef: cellRef,
            sheetApp: sheetApp,
            loggedAtBlock: block.number,
            valueHash: valueHash,
            exists: true
        });
        _cellRefList.push(cellRef);
        totalCellsLogged += 1;
        emit TurboCellLogged(cellRef, sheetApp, block.number, valueHash);
    }

    function logSheetCell(bytes32 cellRef, uint8 sheetApp, bytes32 valueHash)
        external
        onlySheetOracle
        whenNotPaused
        nonReentrant
    {
        _logCellOne(cellRef, sheetApp, valueHash);
    }

    function logSheetCellBatch(bytes32[] calldata cellRefs, uint8[] calldata sheetApps, bytes32[] calldata valueHashes)
        external
        onlySheetOracle
        whenNotPaused
        nonReentrant
    {
        if (cellRefs.length == 0) revert OffClawTurbo_ZeroLength();
        if (cellRefs.length > MAX_BATCH_CELLS) revert OffClawTurbo_BatchTooLarge();
        if (cellRefs.length != sheetApps.length || cellRefs.length != valueHashes.length) revert OffClawTurbo_ArrayLengthMismatch();
        for (uint256 i = 0; i < cellRefs.length; i++) _logCellOne(cellRefs[i], sheetApps[i], valueHashes[i]);
        emit TurboCellBatchLogged(cellRefs, msg.sender, cellRefs.length);
    }

    function _reserveOne(bytes32 slotId, uint8 inboxType) internal {
        if (slotId == bytes32(0)) revert OffClawTurbo_ZeroDocId();
        uint256 slotIndex = uint256(keccak256(abi.encodePacked(slotId))) % TURBO_INBOX_SLOTS;
        while (_inboxSlots[slotIndex].exists) slotIndex = (slotIndex + 1) % TURBO_INBOX_SLOTS;
        _inboxSlots[slotIndex] = TurboInboxSlot({
            slotId: slotId,
            reservedBy: msg.sender,
            inboxType: inboxType,
            reservedAtBlock: block.number,
            exists: true
        });
        _inboxIdList.push(slotId);
        totalSlotsReserved += 1;
        emit TurboSlotReserved(slotId, msg.sender, inboxType, block.number);
    }

    function reserveInboxSlot(bytes32 slotId, uint8 inboxType) external onlyInboxVault whenNotPaused nonReentrant {
        _reserveOne(slotId, inboxType);
    }

    function reserveInboxSlotBatch(bytes32[] calldata slotIds, uint8[] calldata inboxTypes)
        external
        onlyInboxVault
        whenNotPaused
        nonReentrant
    {
        if (slotIds.length == 0) revert OffClawTurbo_ZeroLength();
        if (slotIds.length > MAX_BATCH_SLOTS) revert OffClawTurbo_BatchTooLarge();
        if (slotIds.length != inboxTypes.length) revert OffClawTurbo_ArrayLengthMismatch();
        for (uint256 i = 0; i < slotIds.length; i++) _reserveOne(slotIds[i], inboxTypes[i]);
        emit TurboSlotBatchReserved(slotIds, msg.sender, slotIds.length);
    }

    function bumpTurboEpoch() external onlySheetOracle nonReentrant {
        if (block.number < genesisBlock + (currentEpoch + 1) * TURBO_EPOCH_BLOCKS) revert OffClawTurbo_EpochWindowNotReached();
        if (currentEpoch >= MAX_TURBO_EPOCHS) return;
        if (_epochAdvanced[currentEpoch]) return;
        uint256 prev = currentEpoch;
        currentEpoch += 1;
        _epochAdvanced[prev] = true;
        emit TurboEpochBumped(prev, currentEpoch, block.number);
    }

    function topTurboTreasury() external payable nonReentrant {
        if (msg.value == 0) return;
        uint256 fee = (msg.value * FEE_BASIS_POINTS) / BASIS_DENOM;
        uint256 toBalance = msg.value - fee;
        turboBalance += toBalance;
        if (fee > 0 && turboFeeRecipient != address(0)) accumulatedFees += fee;
        else turboBalance += fee;
        emit TurboTreasuryTopped(msg.value, msg.sender, turboBalance);
    }

    function withdrawTurboTreasury(address payable to, uint256 amount) external onlyTurboGovernor nonReentrant {
        if (amount == 0) revert OffClawTurbo_WithdrawZero();
        if (amount > turboBalance) amount = turboBalance;
        turboBalance -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "OffClawTurbo: transfer failed");
        emit TurboTreasuryWithdrawn(to, amount, block.number);
    }

    function withdrawTurboFees(address payable to) external onlyTurboGovernor nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert OffClawTurbo_WithdrawZero();
        accumulatedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "OffClawTurbo: fee transfer failed");
        emit TurboFeesWithdrawn(to, amount, block.number);
    }

    receive() external payable {
        turboBalance += msg.value;
        emit TurboTreasuryTopped(msg.value, msg.sender, turboBalance);
    }

    function getDoc(bytes32 docId) external view returns (
        bytes32 id, address enqueuedBy, uint8 docType, uint256 queueEpoch, uint256 enqueuedAtBlock, bytes32 payloadHash, bool processed
    ) {
        TurboDoc storage d = _docs[docId];
        if (d.enqueuedAtBlock == 0) revert OffClawTurbo_DocNotFound();
        return (d.docId, d.enqueuedBy, d.docType, d.queueEpoch, d.enqueuedAtBlock, d.payloadHash, d.processed);
    }

    function getDocFull(bytes32 docId) external view returns (
        bytes32 id,
        address enqueuedBy,
        uint8 docType,
        uint256 queueEpoch,
        uint256 enqueuedAtBlock,
        uint256 updatedAtBlock,
        bytes32 payloadHash,
        bytes32[4] memory tags,
        bool processed,
        bool deprecated
    ) {
        TurboDoc storage d = _docs[docId];
        if (d.enqueuedAtBlock == 0) revert OffClawTurbo_DocNotFound();
        return (
            d.docId, d.enqueuedBy, d.docType, d.queueEpoch, d.enqueuedAtBlock, d.updatedAtBlock,
            d.payloadHash, d.tags, d.processed, d.deprecated
        );
    }

    function getCellSlot(uint256 slotIndex) external view returns (
        bytes32 cellRef, uint8 sheetApp, uint256 loggedAtBlock, bytes32 valueHash, bool exists
    ) {
        TurboCellSlot storage c = _cellSlots[slotIndex];
        return (c.cellRef, c.sheetApp, c.loggedAtBlock, c.valueHash, c.exists);
    }

    function getInboxSlot(uint256 slotIndex) external view returns (
        bytes32 slotId, address reservedBy, uint8 inboxType, uint256 reservedAtBlock, bool exists
    ) {
        TurboInboxSlot storage s = _inboxSlots[slotIndex];
        return (s.slotId, s.reservedBy, s.inboxType, s.reservedAtBlock, s.exists);
    }

    function docCount() external view returns (uint256) { return _docIdList.length; }
    function docIdAt(uint256 index) external view returns (bytes32) { return _docIdList[index]; }
    function docsInEpoch(uint256 epoch) external view returns (uint256) { return _docsInEpoch[epoch]; }
    function cellCount() external view returns (uint256) { return _cellRefList.length; }
    function cellRefAt(uint256 index) external view returns (bytes32) { return _cellRefList[index]; }
    function inboxCount() external view returns (uint256) { return _inboxIdList.length; }
    function inboxIdAt(uint256 index) external view returns (bytes32) { return _inboxIdList[index]; }

    function getDocIdRange(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 n = _docIdList.length;
        if (offset >= n) return new bytes32[](0);
        if (offset + limit > n) limit = n - offset;
        ids = new bytes32[](limit);
        for (uint256 i = 0; i < limit; i++) ids[i] = _docIdList[offset + i];
    }

    function getCellRefRange(uint256 offset, uint256 limit) external view returns (bytes32[] memory refs) {
        uint256 n = _cellRefList.length;
        if (offset >= n) return new bytes32[](0);
        if (offset + limit > n) limit = n - offset;
        refs = new bytes32[](limit);
        for (uint256 i = 0; i < limit; i++) refs[i] = _cellRefList[offset + i];
    }

    function getInboxIdRange(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 n = _inboxIdList.length;
        if (offset >= n) return new bytes32[](0);
        if (offset + limit > n) limit = n - offset;
        ids = new bytes32[](limit);
        for (uint256 i = 0; i < limit; i++) ids[i] = _inboxIdList[offset + i];
    }

    function getTurboStats() external view returns (TurboStats memory s) {
        s = TurboStats({
            totalDocs: _docIdList.length,
            totalCells: _cellRefList.length,
            totalInbox: _inboxIdList.length,
            currentEpoch: currentEpoch,
            balance: turboBalance,
            fees: accumulatedFees,
            isPaused: paused
        });
    }

    function getEpochInfo(uint256 epoch) external view returns (EpochInfo memory info) {
        info.epoch = epoch;
        info.docsInEpoch = _docsInEpoch[epoch];
        info.advanced = _epochAdvanced[epoch];
        info.blockStart = genesisBlock + epoch * TURBO_EPOCH_BLOCKS;
        info.blockEnd = genesisBlock + (epoch + 1) * TURBO_EPOCH_BLOCKS - 1;
    }
