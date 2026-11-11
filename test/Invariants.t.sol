// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";
import {IPublicTreasury} from "../src/interfaces/IPublicTreasury.sol";
import {USD} from "./PublicTreasury.t.sol";

/// Drives the treasury through random sequences of everything any party can do: fund it,
/// make, end, claim and close commitments, report units, withdraw earnings, and let time
/// pass, in an ERC-20 and in the native currency. One address is both a payee and a meter.
/// Every claim and withdrawal of a nonzero amount must succeed.
contract Handler is Test {
    PublicTreasury public tr;
    USD public usd;

    address public constant GOV = address(0x60F);
    address public constant FUNDER = address(0xF0);
    address[3] public payees = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public meters = [address(0x3E1), address(0xA1)]; // 0xA1 is also a payee
    address[3] public workers = [address(0xB1), address(0xB2), address(0xB3)];

    uint256 public minted;
    uint256 public mintedNative;
    uint256 public claims;
    uint256 public withdrawals;
    uint256 public ends;
    uint256 public closes;
    uint256 public reports;

    constructor() {
        tr = new PublicTreasury(GOV, 3 days, 365 days, 3000);
        usd = new USD();
        _fund(1_000_000);
    }

    function _fund(uint256 a) internal {
        usd.mint(address(tr), a);
        minted += a;
        vm.deal(address(tr), address(tr).balance + a);
        mintedNative += a;
    }

    function fund(uint256 a) external {
        _fund(bound(a, 1, 1_000_000));
    }

    function _asset(bool native) internal view returns (address) {
        return native ? address(0) : address(usd);
    }

    function _bal(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(tr).balance : usd.balanceOf(address(tr));
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 40 days));
    }

    function createGrant(uint256 who, uint256 per, uint256 period, uint256 n, bool native) external {
        address asset = _asset(native);
        uint64 p = uint64(bound(period, 1 days, 60 days));
        uint32 k = uint32(bound(n, 1, 365 days / p));
        uint256 x = bound(per, 1, 100_000);
        address payee = payees[who % 3];
        uint256 total = x * k;
        uint256 cap = _bal(asset) * 3000 / 10_000;
        if (total > tr.availableOf(asset) || tr.outstandingOf(asset, payee) + total > cap) return;
        vm.prank(GOV);
        tr.createGrant(payee, asset, x, p, k);
    }

    function createProgram(uint256 who, uint256 rate, uint256 budget, uint256 duration, bool native) external {
        address asset = _asset(native);
        address meter = meters[who % 2];
        uint256 r = bound(rate, 1, 1_000);
        uint256 b = bound(budget, 1, 200_000);
        uint64 d = uint64(bound(duration, 1 days, 365 days));
        uint256 cap = _bal(asset) * 3000 / 10_000;
        if (b > tr.availableOf(asset) || tr.outstandingOf(asset, meter) + b > cap) return;
        vm.prank(GOV);
        tr.createProgram(meter, asset, r, b, d);
    }

    function endGrant(uint256 seed) external {
        uint256 n = tr.grantCount();
        if (n == 0) return;
        uint256 id = seed % n;
        IPublicTreasury.Grant memory g = tr.grantOf(id);
        uint256 earned = _earned(g);
        if (earned >= g.periods) return;
        uint256 claimable = tr.claimableOf(id);
        vm.prank(GOV);
        tr.endGrant(id);
        assertEq(tr.claimableOf(id), claimable, "ending keeps what was earned");
        ends++;
    }

    function claimGrant(uint256 seed) external {
        uint256 n = tr.grantCount();
        if (n == 0) return;
        uint256 id = seed % n;
        uint256 c = tr.claimableOf(id);
        if (c == 0) return;
        IPublicTreasury.Grant memory g = tr.grantOf(id);
        uint256 before = _balOf(g.asset, g.payee);
        tr.claimGrant(id); // must not fail
        assertEq(_balOf(g.asset, g.payee) - before, c, "claim pays exactly the claimable amount");
        claims++;
    }

    function report(uint256 seed, uint256 w, uint256 units) external {
        uint256 n = tr.programCount();
        if (n == 0) return;
        uint256 id = seed % n;
        IPublicTreasury.Program memory p = tr.programOf(id);
        if (block.timestamp < p.start || block.timestamp > p.end || p.remaining < p.ratePerUnit) return;
        uint256 u = bound(units, 1, p.remaining / p.ratePerUnit);
        vm.prank(p.meter);
        tr.reportUnits(id, workers[w % 3], u);
        reports++;
    }

    function closeProgram(uint256 seed, bool asGovernor) external {
        uint256 n = tr.programCount();
        if (n == 0) return;
        uint256 id = seed % n;
        IPublicTreasury.Program memory p = tr.programOf(id);
        if (p.remaining == 0) return;
        if (!asGovernor && block.timestamp <= p.end) return;
        vm.prank(asGovernor ? GOV : address(0xBAD));
        tr.closeProgram(id);
        closes++;
    }

    function withdrawEarnings(uint256 w, bool native) external {
        address asset = _asset(native);
        address worker = workers[w % 3];
        uint256 e = tr.earnedOf(asset, worker);
        if (e == 0) return;
        uint256 before = _balOf(asset, worker);
        tr.withdrawEarnings(asset, worker); // must not fail
        assertEq(_balOf(asset, worker) - before, e);
        withdrawals++;
    }

    function _balOf(address asset, address who) internal view returns (uint256) {
        return asset == address(0) ? who.balance : usd.balanceOf(who);
    }

    function _earned(IPublicTreasury.Grant memory g) internal view returns (uint256) {
        if (block.timestamp < g.start) return 0;
        uint256 k = (block.timestamp - g.start) / g.period;
        return k > g.periods ? g.periods : k;
    }

    function holders() external view returns (address[] memory h) {
        h = new address[](8); // the second meter is payees[0]
        h[0] = address(tr);
        for (uint256 i = 0; i < 3; i++) { h[1 + i] = payees[i]; h[4 + i] = workers[i]; }
        h[7] = meters[0];
    }
}

contract InvariantsTest is Test {
    Handler h;

    function setUp() public {
        h = new Handler();
        targetContract(address(h));
    }

    /// committedOf is exactly the unclaimed grant amounts, unspent budgets and
    /// unwithdrawn earnings, and never exceeds the balance.
    function invariant_committed_is_exact_and_funded() public view {
        _committed(address(h.usd()), h.usd().balanceOf(address(h.tr())));
        _committed(address(0), address(h.tr()).balance);
    }

    function _committed(address usd, uint256 balance) internal view {
        PublicTreasury tr = h.tr();
        uint256 sum;
        for (uint256 i = 0; i < tr.grantCount(); i++) {
            IPublicTreasury.Grant memory g = tr.grantOf(i);
            if (g.asset == usd) sum += uint256(g.periods - g.claimedPeriods) * g.perPeriod;
        }
        for (uint256 i = 0; i < tr.programCount(); i++) {
            IPublicTreasury.Program memory p = tr.programOf(i);
            if (p.asset == usd) sum += p.remaining;
        }
        for (uint256 i = 0; i < 3; i++) sum += tr.earnedOf(usd, h.workers(i));
        assertEq(tr.committedOf(usd), sum, "committed");
        assertLe(sum, balance, "funded");
    }

    /// outstandingOf is exactly each recipient's unclaimed grants and unspent budgets.
    function invariant_outstanding_is_exact() public view {
        _outstanding(address(h.usd()));
        _outstanding(address(0));
    }

    function _outstanding(address usd) internal view {
        PublicTreasury tr = h.tr();
        for (uint256 r = 0; r < 5; r++) {
            address who = r < 3 ? h.payees(r) : h.meters(r - 3);
            uint256 sum;
            for (uint256 i = 0; i < tr.grantCount(); i++) {
                IPublicTreasury.Grant memory g = tr.grantOf(i);
                if (g.payee == who && g.asset == usd) sum += uint256(g.periods - g.claimedPeriods) * g.perPeriod;
            }
            for (uint256 i = 0; i < tr.programCount(); i++) {
                IPublicTreasury.Program memory p = tr.programOf(i);
                if (p.meter == who && p.asset == usd) sum += p.remaining;
            }
            assertEq(tr.outstandingOf(usd, who), sum);
        }
    }

    /// Money only moves between the treasury and the recipients; none is created or lost.
    function invariant_tokens_conserved() public view {
        address[] memory hs = h.holders();
        uint256 sum;
        uint256 native;
        for (uint256 i = 0; i < hs.length; i++) {
            sum += h.usd().balanceOf(hs[i]);
            native += hs[i].balance;
        }
        assertEq(sum, h.minted());
        assertEq(native, h.mintedNative());
    }

    /// A meter that is only a meter, and the governor, never receive money.
    function invariant_only_recipients_are_paid() public view {
        assertEq(h.usd().balanceOf(h.meters(0)), 0);
        assertEq(h.meters(0).balance, 0);
        assertEq(h.usd().balanceOf(h.GOV()), 0);
        assertEq(h.GOV().balance, 0);
    }
}
