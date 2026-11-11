// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice A public treasury that pays out only through announced, funded and capped
///         commitments: grants (a fixed amount per period) and programs (a rate per unit
///         of work reported by a meter).
interface IPublicTreasury {
    struct Grant {
        address payee;
        address asset;
        uint128 perPeriod;
        uint64 period;
        uint64 start;
        uint32 periods;        // after the grant is ended: the periods it earned
        uint32 claimedPeriods;
    }

    struct Program {
        address meter;
        address asset;
        uint128 ratePerUnit;
        uint64 start;
        uint64 end;            // last second at which units are accepted
        uint256 remaining;     // budget not yet earned
    }

    event GrantCreated(uint256 indexed id, address indexed payee, address indexed asset,
                       uint256 perPeriod, uint64 period, uint32 periods, uint64 start);
    event GrantClaimed(uint256 indexed id, address indexed payee, uint256 amount);
    event GrantEnded(uint256 indexed id, uint32 periodsEarned, uint256 released);
    event ProgramCreated(uint256 indexed id, address indexed meter, address indexed asset,
                         uint256 ratePerUnit, uint256 budget, uint64 start, uint64 end);
    event UnitsReported(uint256 indexed id, address indexed worker, uint256 units, uint256 amount);
    event ProgramClosed(uint256 indexed id, uint256 released);
    event EarningsWithdrawn(address indexed asset, address indexed worker, uint256 amount);

    /// @notice The only address that can make and end commitments.
    function governor() external view returns (address);
    /// @notice Time between making a commitment and the moment money can flow under it.
    function noticePeriod() external view returns (uint64);
    /// @notice The longest term of any grant or program.
    function maxTerm() external view returns (uint64);
    /// @notice The share of the balance one recipient may hold outstanding, in basis points.
    function recipientCapBps() external view returns (uint16);

    /// @notice Unclaimed grant amounts, unspent budgets and unwithdrawn earnings in `asset`.
    function committedOf(address asset) external view returns (uint256);
    /// @notice The balance of `asset` not committed to anyone.
    function availableOf(address asset) external view returns (uint256);
    /// @notice Unclaimed grant amounts and unspent budgets held by `recipient` (a grant's
    ///         payee or a program's meter) in `asset`.
    function outstandingOf(address asset, address recipient) external view returns (uint256);
    /// @notice What `worker` has earned through programs in `asset` and not yet withdrawn.
    function earnedOf(address asset, address worker) external view returns (uint256);

    function grantCount() external view returns (uint256);
    function grantOf(uint256 id) external view returns (Grant memory);
    /// @notice What the payee of grant `id` can claim now.
    function claimableOf(uint256 id) external view returns (uint256);
    function programCount() external view returns (uint256);
    function programOf(uint256 id) external view returns (Program memory);

    /// @notice Promise `payee` `perPeriod` of `asset` at the end of each of `periods`
    ///         periods, the first starting `noticePeriod` from now. Governor only.
    function createGrant(address payee, address asset, uint256 perPeriod, uint64 period, uint32 periods)
        external returns (uint256 id);
    /// @notice End grant `id` now; earned periods stay claimable. Governor only.
    function endGrant(uint256 id) external;
    /// @notice Pay grant `id`'s payee what it has earned and not claimed. Anyone may call.
    function claimGrant(uint256 id) external;

    /// @notice Pay `ratePerUnit` of `asset` per unit `meter` reports, up to `budget`, for
    ///         `duration` from `noticePeriod` from now. Governor only.
    function createProgram(address meter, address asset, uint256 ratePerUnit, uint256 budget, uint64 duration)
        external returns (uint256 id);
    /// @notice `worker` did `units` of program `id`'s work. The program's meter only; the
    ///         worker cannot be zero, the governor or the treasury.
    function reportUnits(uint256 id, address worker, uint256 units) external;
    /// @notice Release program `id`'s unspent budget. While it is running, only the
    ///         governor may call this, and it also stops the program; after its end, anyone.
    function closeProgram(uint256 id) external;
    /// @notice Pay `worker` its program earnings in `asset`. Anyone may call.
    function withdrawEarnings(address asset, address worker) external;
}
