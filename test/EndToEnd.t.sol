// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {ExampleEscrow} from "settlement-deductions/examples/ExampleEscrow.sol";
import {TaxSchedule} from "../src/TaxSchedule.sol";
import {PublicTreasury} from "../src/PublicTreasury.sol";

contract USDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Tax withheld at settlement by a deduction policy reaches the treasury and pays a
/// judge per case.
contract EndToEndTest is Test {
    USDC usdc;
    PublicTreasury treasury;
    TaxSchedule schedule;
    SettlementDeductionPolicy policy;
    ExampleEscrow escrow;

    address gov = address(0x60F);       // stands in for a collective decision's executor
    address client = address(0xC11);
    address worker = address(0xCAFE);
    address judge = address(0x1CDE);
    address meter = address(0x3E7);     // stands in for a dispute-resolution adapter
    uint256 constant U = 1e6;

    function setUp() public {
        usdc = new USDC();
        treasury = new PublicTreasury(gov, 3 days, 365 days, 3000);
        schedule = new TaxSchedule(gov, address(treasury), 500, 7 days);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        policy = new SettlementDeductionPolicy(next, schedule, 3000);
        escrow = new ExampleEscrow(policy);
        require(address(escrow) == next, "deploy order");

        vm.prank(gov);
        schedule.proposeRate(address(usdc), 100); // 1%
        vm.warp(block.timestamp + 7 days);
        usdc.mint(client, 100_000 * U);
    }

    function _runTask(uint256 reward) internal returns (uint256 id) {
        vm.startPrank(client);
        usdc.approve(address(escrow), reward);
        id = escrow.createTask(address(usdc), reward, worker);
        escrow.pay(id);
        vm.stopPrank();
    }

    function test_tax_flows_to_the_treasury_and_pays_a_judge_per_case() public {
        // 1. Ten tasks of 1,000 settle; 1% of each is withheld for the treasury.
        uint256[] memory ids = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) ids[i] = _runTask(1_000 * U);
        assertEq(usdc.balanceOf(worker), 10 * 990 * U);

        // 2. Anyone collects the tax into the treasury.
        for (uint256 i = 0; i < 10; i++) policy.claim(ids[i], address(treasury));
        assertEq(usdc.balanceOf(address(treasury)), 100 * U);

        // 3. The governor funds a judging program: 5 per case, budget 30 (within the 30% cap).
        vm.prank(gov);
        uint256 pid = treasury.createProgram(meter, address(usdc), 5 * U, 30 * U, 90 days);
        vm.warp(block.timestamp + 3 days);

        // 4. The judge rules four cases; the meter reports them; the earnings are withdrawn.
        vm.prank(meter);
        treasury.reportUnits(pid, judge, 4);
        treasury.withdrawEarnings(address(usdc), judge);
        assertEq(usdc.balanceOf(judge), 20 * U);
        assertEq(treasury.availableOf(address(usdc)), 70 * U, "100 in, 20 paid, 10 still budgeted");
    }

    /// Why the ERC recommends a schedule ceiling within every reading policy's cap: a rate
    /// above the policy's cap makes the policy refuse every new task.
    function test_a_rate_above_the_policy_cap_stops_task_creation() public {
        TaxSchedule loose = new TaxSchedule(gov, address(treasury), 500, 7 days);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SettlementDeductionPolicy strict = new SettlementDeductionPolicy(next, loose, 300);
        ExampleEscrow e = new ExampleEscrow(strict);
        vm.prank(gov);
        loose.proposeRate(address(usdc), 400);
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(client);
        usdc.approve(address(e), 1_000 * U);
        vm.expectRevert("Deductions: tax above cap");
        e.createTask(address(usdc), 1_000 * U, worker);
        vm.stopPrank();
    }

    function test_native_currency_end_to_end() public {
        vm.prank(gov);
        schedule.proposeRate(address(0), 200); // 2%
        vm.warp(block.timestamp + 7 days);
        vm.deal(client, 10 ether);
        vm.startPrank(client);
        uint256 id = escrow.createTask{value: 10 ether}(address(0), 10 ether, worker);
        escrow.pay(id);
        vm.stopPrank();
        assertEq(worker.balance, 9.8 ether);
        policy.claim(id, address(treasury));
        assertEq(address(treasury).balance, 0.2 ether);
        vm.prank(gov);
        uint256 g = treasury.createGrant(judge, address(0), 0.05 ether, 1 days, 1);
        vm.warp(block.timestamp + 3 days + 1 days);
        treasury.claimGrant(g);
        assertEq(judge.balance, 0.05 ether);
    }

    function test_a_rate_change_reaches_only_new_tasks() public {
        uint256 before = _runTask(1_000 * U);
        vm.prank(gov);
        schedule.proposeRate(address(usdc), 300); // 3%
        uint256 duringNotice = _runTask(1_000 * U);
        vm.warp(block.timestamp + 7 days);
        uint256 later = _runTask(1_000 * U);
        assertEq(policy.owedOf(before, address(treasury)), 10 * U);
        assertEq(policy.owedOf(duringNotice, address(treasury)), 10 * U, "the notice protects tasks made meanwhile");
        assertEq(policy.owedOf(later, address(treasury)), 30 * U);
    }
}
