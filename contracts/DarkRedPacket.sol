// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DarkRedPacket — 暗池抢红包
 * @notice 庄家发红包，参与者暗标出价。出价太贪空手而归，太保守拿太少。
 *
 * 三阶段流程:
 * 1. Commit: 参与者提交 Poseidon(amount, secret) 密封出价
 * 2. Reveal: 参与者揭示 amount + secret，合约用 Poseidon 预编译验证
 * 3. Settle: reveal 结束后，按 blockhash 随机顺序处理出价（真暗池）
 *
 * 暗池设计:
 * - commit 阶段看不到任何人的出价
 * - reveal 阶段所有人先揭示，不立即处理
 * - settle 阶段用 reveal 截止块的 blockhash 决定处理顺序
 * - 没有先手优势，没有信息优势，纯策略博弈
 */
contract DarkRedPacket {
    // ============ 预编译 ============
    address constant POSEIDON = 0x0000000000000000000000000000000000000810;

    // ============ 配置 ============
    address public owner;
    uint256 public feeBps = 200; // 2% 手续费归合约 owner
    uint256 public minPacketAmount = 10 ether; // 最小红包 10 AXON
    uint256 public minEntryFee = 1 ether; // 最小参与费 1 AXON
    uint256 public maxParticipants = 50; // 最大参与人数

    // ============ 红包状态 ============
    struct Packet {
        address creator;
        uint256 totalAmount;
        uint256 remaining;
        uint256 entryFee;
        uint256 commitDeadline;
        uint256 revealDeadline;
        uint256 participantCount;
        uint256 revealCount;
        uint256 feeBps;          // 快照创建时的手续费
        bytes32 settleSeed;      // 快照 blockhash 用于延迟结算
        bool settled;
    }

    uint256 public nextPacketId;
    mapping(uint256 => Packet) public packets;

    // ============ 参与者状态 ============
    mapping(uint256 => mapping(address => bytes32)) public commitments;
    mapping(uint256 => mapping(address => uint256)) public revealedAmounts;
    mapping(uint256 => mapping(address => bool)) public hasRevealed;
    mapping(uint256 => mapping(address => bool)) public hasWithdrawn;

    // reveal 的参与者列表（settle 时随机排序处理）
    mapping(uint256 => address[]) public revealedPlayers;

    // settle 后的结果
    mapping(uint256 => mapping(address => uint256)) public winnings;

    // 庄家待提取金额 (pull payment)
    mapping(uint256 => uint256) public creatorClaimable;

    // ============ 金库 ============
    uint256 public treasury;

    // ============ 重入锁 ============
    bool private _locked;

    // ============ 事件 ============
    event PacketCreated(uint256 indexed packetId, address indexed creator, uint256 amount, uint256 entryFee, uint256 commitDeadline, uint256 revealDeadline);
    event Committed(uint256 indexed packetId, address indexed participant);
    event Revealed(uint256 indexed packetId, address indexed participant);
    event Settled(uint256 indexed packetId, uint256 totalGrabbed, uint256 returnedToCreator, uint256 fee);
    event Grabbed(uint256 indexed packetId, address indexed participant, uint256 amount, uint256 order);
    event Greedy(uint256 indexed packetId, address indexed participant, uint256 amount, uint256 order);
    event Withdrawn(uint256 indexed packetId, address indexed participant, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    // ============ 修饰器 ============
    modifier noReentrant() {
        require(!_locked, "no reentrancy");
        _locked = true;
        _;
        _locked = false;
    }

    // ============ 构造函数 ============
    constructor() {
        owner = msg.sender;
    }

    // ============ 庄家: 创建红包 ============
    function createPacket(
        uint256 entryFee,
        uint256 commitBlocks,
        uint256 revealBlocks
    ) external payable returns (uint256 packetId) {
        require(msg.value >= minPacketAmount, "too small");
        require(entryFee >= minEntryFee, "entry fee too low");
        require(commitBlocks >= 10, "commit window too short");
        require(revealBlocks >= 10, "reveal window too short");

        packetId = nextPacketId++;
        packets[packetId] = Packet({
            creator: msg.sender,
            totalAmount: msg.value,
            remaining: msg.value,
            entryFee: entryFee,
            commitDeadline: block.number + commitBlocks,
            revealDeadline: block.number + commitBlocks + revealBlocks,
            participantCount: 0,
            revealCount: 0,
            feeBps: feeBps,
            settleSeed: bytes32(0),
            settled: false
        });

        emit PacketCreated(packetId, msg.sender, msg.value, entryFee, block.number + commitBlocks, block.number + commitBlocks + revealBlocks);
    }

    // ============ 参与者: 提交密封出价 ============
    function commit(uint256 packetId, bytes32 commitment) external payable {
        Packet storage p = packets[packetId];
        require(block.number <= p.commitDeadline, "commit closed");
        require(commitments[packetId][msg.sender] == bytes32(0), "already committed");
        require(commitment != bytes32(0), "empty commitment");
        require(p.participantCount < maxParticipants, "packet full");
        require(msg.value == p.entryFee, "wrong entry fee");

        commitments[packetId][msg.sender] = commitment;
        p.participantCount += 1;

        emit Committed(packetId, msg.sender);
    }

    // ============ 参与者: 揭示出价 ============
    function reveal(uint256 packetId, uint256 amount, uint256 secret) external {
        Packet storage p = packets[packetId];
        require(block.number > p.commitDeadline, "commit phase active");
        require(block.number <= p.revealDeadline, "reveal closed");
        require(!hasRevealed[packetId][msg.sender], "already revealed");

        bytes32 commitment = commitments[packetId][msg.sender];
        require(commitment != bytes32(0), "not committed");
        require(amount > 0, "zero amount");

        // 用 Poseidon 预编译验证: hash2(amount, secret) == commitment
        bytes32 computed = _poseidonHash2(bytes32(amount), bytes32(secret));
        require(computed == commitment, "invalid reveal");

        hasRevealed[packetId][msg.sender] = true;
        revealedAmounts[packetId][msg.sender] = amount;
        revealedPlayers[packetId].push(msg.sender);
        p.revealCount += 1;

        emit Revealed(packetId, msg.sender);
    }

    // ============ 结算: reveal 结束后任何人可调 ============
    function settle(uint256 packetId) external noReentrant {
        Packet storage p = packets[packetId];
        require(block.number > p.revealDeadline, "reveal not ended");
        require(!p.settled, "already settled");

        // Axon 链 (Cosmos-EVM) 的 blockhash opcode 返回 0
        // 使用 block.prevrandao + block 元数据组合作为随机种子
        bytes32 seed = keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            block.number,
            msg.sender,
            packetId
        ));
        p.settleSeed = seed;

        p.settled = true;

        address[] storage players = revealedPlayers[packetId];
        uint256 n = players.length;

        uint256 remaining = p.totalAmount;
        uint256 totalGrabbed = 0;
        uint256 actualFee = 0;

        if (n > 0) {
            // Fisher-Yates shuffle
            uint256[] memory order = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                order[i] = i;
            }
            for (uint256 i = n - 1; i > 0; i--) {
                uint256 j = uint256(keccak256(abi.encodePacked(seed, i))) % (i + 1);
                (order[i], order[j]) = (order[j], order[i]);
            }

            // 按随机顺序处理出价，同时精确计算手续费
            for (uint256 k = 0; k < n; k++) {
                address player = players[order[k]];
                uint256 amount = revealedAmounts[packetId][player];

                if (amount <= remaining) {
                    uint256 playerFee = (amount * p.feeBps) / 10000;
                    winnings[packetId][player] = amount - playerFee;
                    actualFee += playerFee;
                    remaining -= amount;
                    totalGrabbed += amount;
                    emit Grabbed(packetId, player, amount, k);
                } else {
                    emit Greedy(packetId, player, amount, k);
                }
            }
        }

        treasury += actualFee;
        p.remaining = remaining;

        // 庄家可提取: 红包余额 + revealed 参与者的参与费
        // 未 reveal 参与者的参与费留在合约供 refundEntry 退回
        uint256 revealedEntryFees = p.entryFee * p.revealCount;
        creatorClaimable[packetId] = remaining + revealedEntryFees;

        emit Settled(packetId, totalGrabbed, remaining + revealedEntryFees, actualFee);
    }

    // ============ 庄家提取: settle 后庄家取回余额和参与费 ============
    function creatorWithdraw(uint256 packetId) external noReentrant {
        require(packets[packetId].settled, "not settled");
        uint256 amount = creatorClaimable[packetId];
        require(amount > 0, "nothing to claim");
        require(msg.sender == packets[packetId].creator, "not creator");

        creatorClaimable[packetId] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }

    // ============ 庄家紧急回收: 无人 reveal 时回收红包 ============
    function creatorReclaim(uint256 packetId) external {
        Packet storage p = packets[packetId];
        require(msg.sender == p.creator, "not creator");
        require(!p.settled, "already settled");
        require(block.number > p.revealDeadline, "reveal not ended");

        // 只有无人 reveal 才能 reclaim（有 reveal 必须走 settle）
        require(p.revealCount == 0, "has reveals, use settle");

        p.settled = true;
        p.remaining = 0;

        // 红包金额 + 所有参与者的参与费（revealed 的人也退参与费）
        uint256 totalEntryFees = p.entryFee * p.participantCount;
        creatorClaimable[packetId] = p.totalAmount + totalEntryFees;
    }

    // ============ 赢家: 提取奖金 ============
    function withdraw(uint256 packetId) external noReentrant {
        require(packets[packetId].settled, "not settled");
        require(!hasWithdrawn[packetId][msg.sender], "already withdrawn");

        uint256 amount = winnings[packetId][msg.sender];
        require(amount > 0, "nothing to withdraw");

        hasWithdrawn[packetId][msg.sender] = true;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit Withdrawn(packetId, msg.sender, amount);
    }

    // ============ 参与者: 退回参与费 ============
    // 未 reveal 的人: reveal 结束后随时可退
    // 已 reveal 的人: 仅当红包被 creatorReclaim（failed 状态）时可退
    function refundEntry(uint256 packetId) external noReentrant {
        Packet storage p = packets[packetId];
        require(block.number > p.revealDeadline, "reveal not ended");
        require(p.entryFee > 0, "no entry fee");
        require(commitments[packetId][msg.sender] != bytes32(0), "not committed");
        require(!hasWithdrawn[packetId][msg.sender], "already refunded");

        if (hasRevealed[packetId][msg.sender]) {
            // revealed 玩家只能在 failed reclaim 后退费（正常 settle 后不能退）
            require(p.settled && winnings[packetId][msg.sender] == 0 && creatorClaimable[packetId] > 0, "not eligible");
        }

        hasWithdrawn[packetId][msg.sender] = true;

        (bool ok, ) = msg.sender.call{value: p.entryFee}("");
        require(ok, "refund failed");
    }

    // ============ 查询 ============
    function getPacketInfo(uint256 packetId) external view returns (
        address creator,
        uint256 totalAmount,
        uint256 remaining,
        uint256 entryFee,
        uint256 commitDeadline,
        uint256 revealDeadline,
        uint256 participantCount,
        uint256 revealCount,
        bool settled
    ) {
        Packet storage p = packets[packetId];
        return (p.creator, p.totalAmount, p.remaining, p.entryFee,
                p.commitDeadline, p.revealDeadline, p.participantCount, p.revealCount, p.settled);
    }

    function getRevealedPlayers(uint256 packetId) external view returns (address[] memory) {
        return revealedPlayers[packetId];
    }

    function getMyWinnings(uint256 packetId, address player) external view returns (uint256) {
        return winnings[packetId][player];
    }

    // ============ Poseidon 预编译调用 ============
    function _poseidonHash2(bytes32 left, bytes32 right) internal view returns (bytes32 result) {
        // hash2(bytes32,bytes32) selector
        bytes4 selector = 0xb30c0b6a; // keccak256("hash2(bytes32,bytes32)")[:4]
        (bool ok, bytes memory data) = POSEIDON.staticcall(
            abi.encodeWithSelector(selector, left, right)
        );
        require(ok && data.length >= 32, "poseidon failed");
        result = abi.decode(data, (bytes32));
    }

    // ============ 管理 ============
    function withdrawTreasury() external noReentrant {
        require(msg.sender == owner, "not owner");
        uint256 amount = treasury;
        require(amount > 0, "empty treasury");
        treasury = 0;
        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "transfer failed");
        emit TreasuryWithdrawn(owner, amount);
    }

    function setFeeBps(uint256 _feeBps) external {
        require(msg.sender == owner, "not owner");
        require(_feeBps <= 500, "fee too high"); // max 5%
        feeBps = _feeBps;
    }

    function setMinPacketAmount(uint256 _min) external {
        require(msg.sender == owner, "not owner");
        minPacketAmount = _min;
    }
}
