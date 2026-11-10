// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IPublicTreasury} from "./interfaces/IPublicTreasury.sol";

/// @title  PublicTreasury — a treasury that pays out only through public commitments.
/// @notice Money arrives from anywhere (typically a tax collected at settlement). It
///         leaves only in two ways, and only to the recipient a commitment names:
///
///         Grant   — standing work (maintaining contracts, monitoring): a fixed amount per
///                   period for a fixed term. Renewing means a new grant.
///         Program — piecework (a judge per case ruled): a rate per unit of work, reported
///                   by one meter contract, within a budget and an end date.
///
///         The governor decides; the contract bounds every decision:
///         - a commitment takes effect `noticePeriod` after it is made;
///         - it is funded in full when made: commitments never exceed the balance;
///         - one recipient's outstanding commitments stay within `recipientCapBps` of the
///           balance, and no term is longer than `maxTerm`;
///         - the governor and the treasury itself are never paid;
///         - ending a commitment never takes away what was already earned.
contract PublicTreasury is IPublicTreasury {
    uint16 public constant BPS = 10_000;

    address public immutable governor;
    uint64 public immutable noticePeriod;
    uint64 public immutable maxTerm;
    uint16 public immutable recipientCapBps;

    Grant[] private _grants;
    Program[] private _programs;

    /// asset => unclaimed grant amounts + unspent budgets + unwithdrawn earnings
    mapping(address => uint256) public committedOf;
    /// asset => recipient (payee or meter) => unclaimed grant amounts + unspent budgets
    mapping(address => mapping(address => uint256)) public outstandingOf;
    /// asset => worker => earned through programs, not yet withdrawn
    mapping(address => mapping(address => uint256)) public earnedOf;

    /// Native currency received. ERC-20 inflows are visible as the token's own events.
    event Received(address indexed from, uint256 amount);

    modifier onlyGovernor() {
        require(msg.sender == governor, "Treasury: not governor");
        _;
    }

    constructor(address governor_, uint64 noticePeriod_, uint64 maxTerm_, uint16 recipientCapBps_) {
        require(governor_ != address(0), "Treasury: zero governor");
        require(recipientCapBps_ > 0 && recipientCapBps_ <= BPS, "Treasury: bad cap");
        // A zero term would refuse every commitment, and start + term must never overflow.
        require(maxTerm_ > 0 && uint256(noticePeriod_) + maxTerm_ <= type(uint32).max, "Treasury: bad times");
        governor = governor_;
        noticePeriod = noticePeriod_;
        maxTerm = maxTerm_;
        recipientCapBps = recipientCapBps_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ reads
    /// @inheritdoc IPublicTreasury
    function availableOf(address asset) public view returns (uint256) {
        uint256 bal = _balanceOf(asset);
        uint256 c = committedOf[asset];
        return bal > c ? bal - c : 0;
    }

    function grantCount() external view returns (uint256) { return _grants.length; }
    function grantOf(uint256 id) external view returns (Grant memory) { return _grants[id]; }
    function programCount() external view returns (uint256) { return _programs.length; }
    function programOf(uint256 id) external view returns (Program memory) { return _programs[id]; }

    /// @inheritdoc IPublicTreasury
    function claimableOf(uint256 id) public view returns (uint256) {
        Grant memory g = _grants[id];
        return uint256(_earnedPeriods(g) - g.claimedPeriods) * g.perPeriod;
    }

    // ------------------------------------------------------------------ grants
    /// @inheritdoc IPublicTreasury
    function createGrant(address payee, address asset, uint256 perPeriod, uint64 period, uint32 periods)
        external onlyGovernor returns (uint256 id)
    {
        require(perPeriod > 0 && period > 0 && periods > 0, "Treasury: empty grant");
        require(perPeriod <= type(uint128).max, "Treasury: amount too large");
        require(uint256(period) * periods <= maxTerm, "Treasury: term too long");
        _commit(asset, payee, uint256(perPeriod) * periods);

        uint64 start = uint64(block.timestamp) + noticePeriod;
        id = _grants.length;
        _grants.push(Grant(payee, asset, uint128(perPeriod), period, start, periods, 0));
        emit GrantCreated(id, payee, asset, perPeriod, period, periods, start);
    }

    /// @inheritdoc IPublicTreasury
    function endGrant(uint256 id) external onlyGovernor {
        Grant storage g = _grants[id];
        uint32 earned = _earnedPeriods(g);
        require(earned < g.periods, "Treasury: grant over");
        uint256 released = uint256(g.periods - earned) * g.perPeriod;
        g.periods = earned;
        _release(g.asset, g.payee, released);
        emit GrantEnded(id, earned, released);
    }

    /// @inheritdoc IPublicTreasury
    function claimGrant(uint256 id) external {
        Grant storage g = _grants[id];
        uint32 earned = _earnedPeriods(g);
        uint256 amount = uint256(earned - g.claimedPeriods) * g.perPeriod;
        require(amount > 0, "Treasury: nothing earned");
        g.claimedPeriods = earned;
        _release(g.asset, g.payee, amount);
        emit GrantClaimed(id, g.payee, amount);
        _send(g.asset, g.payee, amount);
    }

    /// Periods finished by now: the k-th ends at start + k * period.
    function _earnedPeriods(Grant memory g) private view returns (uint32) {
        if (block.timestamp < g.start) return 0;
        uint256 n = (block.timestamp - g.start) / g.period;
        return n >= g.periods ? g.periods : uint32(n);
    }

    // ---------------------------------------------------------------- programs
    /// @inheritdoc IPublicTreasury
    function createProgram(address meter, address asset, uint256 ratePerUnit, uint256 budget, uint64 duration)
        external onlyGovernor returns (uint256 id)
    {
        require(ratePerUnit > 0 && budget > 0 && duration > 0, "Treasury: empty program");
        require(ratePerUnit <= type(uint128).max, "Treasury: amount too large");
        require(duration <= maxTerm, "Treasury: term too long");
        _commit(asset, meter, budget);

        uint64 start = uint64(block.timestamp) + noticePeriod;
        uint64 end = start + duration;
        id = _programs.length;
        _programs.push(Program(meter, asset, uint128(ratePerUnit), start, end, budget));
        emit ProgramCreated(id, meter, asset, ratePerUnit, budget, start, end);
    }

    /// @inheritdoc IPublicTreasury
    function reportUnits(uint256 id, address worker, uint256 units) external {
        Program storage p = _programs[id];
        require(msg.sender == p.meter, "Treasury: not meter");
        require(block.timestamp >= p.start && block.timestamp <= p.end, "Treasury: program not running");
        require(worker != address(0) && worker != governor && worker != address(this) && units > 0,
            "Treasury: bad report");
        uint256 amount = units * p.ratePerUnit;
        require(amount <= p.remaining, "Treasury: budget spent");
        p.remaining -= amount;
        outstandingOf[p.asset][p.meter] -= amount;
        earnedOf[p.asset][worker] += amount; // still committed until withdrawn
        emit UnitsReported(id, worker, units, amount);
    }

    /// @inheritdoc IPublicTreasury
    function closeProgram(uint256 id) external {
        Program storage p = _programs[id];
        bool running = block.timestamp <= p.end;
        require(!running || msg.sender == governor, "Treasury: program running");
        uint256 released = p.remaining;
        if (running) p.end = uint64(block.timestamp) - 1; // stopped now, even with nothing left
        else require(released > 0, "Treasury: nothing to release");
        p.remaining = 0;
        _release(p.asset, p.meter, released);
        emit ProgramClosed(id, released);
    }

    /// @inheritdoc IPublicTreasury
    function withdrawEarnings(address asset, address worker) external {
        uint256 amount = earnedOf[asset][worker];
        require(amount > 0, "Treasury: nothing earned");
        earnedOf[asset][worker] = 0;
        committedOf[asset] -= amount;
        emit EarningsWithdrawn(asset, worker, amount);
        _send(asset, worker, amount);
    }

    // ------------------------------------------------------------------ money
    /// Sets `amount` aside for `recipient`: within what is not yet promised, and within
    /// the recipient's cap.
    function _commit(address asset, address recipient, uint256 amount) private {
        require(recipient != address(0) && recipient != governor && recipient != address(this),
            "Treasury: bad recipient");
        require(amount <= availableOf(asset), "Treasury: not enough unpromised money");
        uint256 owed = outstandingOf[asset][recipient] + amount;
        uint256 bal = _balanceOf(asset);
        // floor(bal * cap / BPS), without overflow for any balance
        uint256 cap = bal / BPS * recipientCapBps + bal % BPS * recipientCapBps / BPS;
        require(owed <= cap, "Treasury: recipient cap");
        outstandingOf[asset][recipient] = owed;
        committedOf[asset] += amount;
    }

    function _release(address asset, address recipient, uint256 amount) private {
        outstandingOf[asset][recipient] -= amount;
        committedOf[asset] -= amount;
    }

    function _balanceOf(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _send(address asset, address to, uint256 amount) private {
        bool ok;
        if (asset == address(0)) {
            (ok, ) = payable(to).call{value: amount}("");
        } else {
            bytes memory ret;
            (ok, ret) = asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            // No return data is success only for a contract (tokens that return nothing);
            // a call to an address without code also returns nothing.
            ok = ok && (ret.length == 0 ? asset.code.length > 0 : ret.length >= 32 && abi.decode(ret, (uint256)) != 0);
        }
        require(ok, "Treasury: transfer failed");
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
