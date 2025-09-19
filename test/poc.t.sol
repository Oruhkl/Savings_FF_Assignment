// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TimeLockSavings} from "src/Savings.sol";
import {Test, console2} from "forge-std/Test.sol";



// Mock ERC20 token for testing
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    string public name = "Test Token";
    string public symbol = "TEST";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1000000 * 10**18;
    
    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract TimeLockSavingsPoc is Test {
    TimeLockSavings public savings;
    MockERC20 public token;
    
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    
    uint256 constant DEPOSIT_AMOUNT = 1000 * 10**18;
    uint256 constant MIN_LOCK_PERIOD = 60 days;
    uint256 constant BONUS_PERIOD = 30 days;
    uint256 public constant BASE_REWARD_RATE = 200; // 2% = 200/10000
    uint256 public constant BONUS_REWARD_RATE = 100; // 1% = 100/10000
    uint256 public constant EARLY_PENALTY_RATE = 1000; // 10% = 1000/10000
    uint256 public constant BASIS_POINTS = 10000;
    
    event Deposited(address indexed user, uint256 depositId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 reward, uint256 depositId);
    event EarlyWithdrawn(address indexed user, uint256 amount, uint256 penalty, uint256 depositId);
    
    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        
        // Deploy mock token and savings contract
        token = new MockERC20();
        savings = new TimeLockSavings(address(token));
        
        // Fund users with tokens
        token.mint(user1, type(uint128).max);
        token.mint(user2, type(uint128).max);
        token.mint(user3, type(uint128).max);
        
    }

    // ==================================================
    // BUG 1: WRONG PARAMETER ORDER IN WITHDRAW
    // ==================================================
    
    /// @dev Test that demonstrates the wrong parameter order bug in withdraw()
    function test_bug1_WrongParameterOrder_BasicCase() public {
        // Fund contract with tokens for rewards
        token.mint(address(savings), type(uint128).max);
        uint256 depositAmount = 1000 * 10**18;
        
        vm.startPrank(user1);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        
        // Fast forward past minimum lock period
        vm.warp(block.timestamp + MIN_LOCK_PERIOD);
        uint256 timeElapsed = MIN_LOCK_PERIOD;
        
        // What the reward SHOULD be (correct parameter order)
        uint256 correctReward = savings.calculateReward(depositAmount, timeElapsed);
        
        // What the contract actually calculates (wrong parameter order)
        uint256 buggyReward = savings.calculateReward(timeElapsed, depositAmount);
        
        console2.log("Correct reward:", correctReward);
        console2.log("Buggy reward:", buggyReward);
        console2.log("Difference:", buggyReward > correctReward ? buggyReward - correctReward : correctReward - buggyReward);
        
        // Perform withdrawal and verify it uses buggy calculation
        uint256 balanceBefore = token.balanceOf(user1);
        savings.withdraw(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        uint256 actualReward = balanceAfter - balanceBefore - depositAmount;
        
        // Contract uses wrong parameter order
        assertEq(actualReward, buggyReward, "Contract uses buggy parameter order");
        assertTrue(actualReward != correctReward, "Contract doesn't use correct parameter order");
        
        vm.stopPrank();
    }

    // ==================================================
    // BUG 2: EVENT PARAMETER ORDER BUG
    // ==================================================
    
    /// @dev Test that demonstrates wrong event parameter order in deposit()
    function test_bug2_EventParameterOrder() public {
        uint256 depositAmount = 1000 * 10**18;
        
        vm.startPrank(user1);
        token.approve(address(savings), depositAmount);
        
        // The event signature expects (user, amount, depositId) 
        // But the contract emits (user, depositId, amount)
        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, 0, depositAmount); // Wrong order: depositId=0, amount=depositAmount
        
        savings.deposit(depositAmount);
        
        vm.stopPrank();
    }

    // ==================================================
    // BUG 3: DEPOSIT STATE INCONSISTENCY AFTER WITHDRAWAL
    // ==================================================
    
    /// @dev Test that shows deposit amount isn't reset after withdrawal
    function test_bug3_DepositStateAfterWithdrawal() public {
        // Fund contract with tokens for rewards
        token.mint(address(savings), type(uint128).max);
        uint256 depositAmount = 1000 * 10**18;
        
        vm.startPrank(user1);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        
        // Fast forward and withdraw
        vm.warp(block.timestamp + MIN_LOCK_PERIOD);
        savings.withdraw(0);
        
        // Check deposit state after withdrawal
        (uint256 amount, uint256 depositTime, bool withdrawn) = savings.userDeposits(user1, 0);
        
        console2.log("After withdrawal:");
        console2.log("Amount:", amount);
        console2.log("Withdrawn:", withdrawn);
        
        // Bug: amount is still non-zero even though withdrawn = true
        assertTrue(withdrawn, "Should be marked as withdrawn");
        assertEq(amount, depositAmount, "Amount should still be set (this is the bug)");
        // Ideally, amount should be 0 after withdrawal for cleaner state
        
        vm.stopPrank();
    }
    // BUG 4: PRECISION LOSS IN REWARD CALCULATIONS
    // ==================================================
    
    /// @dev Test precision loss for very small amounts
    function test_bug4_PrecisionLoss_VerySmallAmounts() public {
        // Test amounts that cause precision loss
        uint256[] memory smallAmounts = new uint256[](10);
        smallAmounts[0] = 1;    // 1 wei
        smallAmounts[1] = 10;   // 10 wei  
        smallAmounts[2] = 25;   // 25 wei
        smallAmounts[3] = 49;   // 49 wei
        smallAmounts[4] = 50;   // 50 wei - threshold
        smallAmounts[5] = 99;   // 99 wei
        smallAmounts[6] = 100;  // 100 wei
        smallAmounts[7] = 499;  // 499 wei
        smallAmounts[8] = 500;  // 500 wei
        smallAmounts[9] = 1000; // 1000 wei
        
        console2.log("=== PRECISION LOSS TEST ===");
        
        for (uint256 i = 0; i < smallAmounts.length; i++) {
            uint256 amount = smallAmounts[i];
            uint256 reward = savings.calculateReward(amount, MIN_LOCK_PERIOD);
            
            console2.log("Amount:", amount, "wei -> Reward:", reward);
            
            // Calculate expected reward with perfect precision
            uint256 expectedNumerator = amount * BASE_REWARD_RATE;
            bool shouldHaveReward = expectedNumerator >= BASIS_POINTS;
            
            if (shouldHaveReward && reward == 0) {
                console2.log("  ^^ PRECISION LOSS DETECTED ^^");
            }
        }
        
        // Verify precision loss threshold
        uint256 minAmountForReward = BASIS_POINTS / BASE_REWARD_RATE; // Should be 50
        console2.log("Minimum amount for reward:", minAmountForReward);
        
        assertEq(savings.calculateReward(minAmountForReward - 1, MIN_LOCK_PERIOD), 0, "Below threshold should be 0");
        assertGt(savings.calculateReward(minAmountForReward, MIN_LOCK_PERIOD), 0, "At threshold should be > 0");
    }

    /// @dev Test that constructor accepts zero address (should not)
    function test_bug5_ConstructorNoValidation() public {
        // This should ideally fail but currently doesn't
        TimeLockSavings invalidSavings = new TimeLockSavings(address(0));
        
        // Verify the contract was created with zero address
        assertEq(address(invalidSavings.token()), address(0), "Contract accepts zero address token");
        
        // This makes the contract non-functional
        // Any attempt to use it would fail in token operations
    }
    function test_USDTCompatibility() public {
        MockUSDT usdt = new MockUSDT();
        TimeLockSavings usdtSavings = new TimeLockSavings(address(usdt));
        // Fund users with tokens
        usdt.mint(user1, type(uint128).max);
        vm.startPrank(user1);
        usdt.approve(address(usdtSavings), 1000);
        
        // This will fail due to missing return value
        vm.expectRevert();
        usdtSavings.deposit(1000);
    }
    function test_bug6_UnfairRewardCliffProblem() public {
        console2.log("=== UNFAIR REWARD CLIFF PROBLEM ===");
        
        uint256 depositAmount = 1000 * 10**18; // 1000 tokens
        uint256 minLock = MIN_LOCK_PERIOD;
        
        // Test periods around the bonus threshold
        uint256 period1 = minLock + 29 days;  // 1 day before bonus
        uint256 period2 = minLock + 29 days + 23 hours + 59 minutes + 59 seconds; // 1 second before bonus
        uint256 period3 = minLock + 30 days;  // Exactly at bonus threshold
        
        uint256 reward1 = savings.calculateReward(depositAmount, period1);
        uint256 reward2 = savings.calculateReward(depositAmount, period2);
        uint256 reward3 = savings.calculateReward(depositAmount, period3);
        
        console2.log("89 days reward:", reward1 / 10**18, "tokens");
        console2.log("89 days 23:59:59 reward:", reward2 / 10**18, "tokens");
        console2.log("90 days reward:", reward3 / 10**18, "tokens");
        
        // Demonstrate the cliff: 1 second makes massive difference
        console2.log("CLIFF EFFECT: 1 second difference -> Reward jumps from", 
                    reward2 / 10**18, "to tokens :", 
                    reward3 / 10**18);
        
        assertTrue(reward3 > reward2, "Should get more reward after threshold");
        assertEq(reward3 - reward2, 10 * 10**18, "Should get exactly 10 token bonus at cliff");
        
        // This demonstrates the unfairness: 89 days gets same reward as 60 days!
        uint256 reward60Days = savings.calculateReward(depositAmount, minLock);
        assertEq(reward1, reward60Days, "89 days gets same reward as 60 days (UNFAIR!)");
        assertTrue(reward3 > reward1, "90 days should get more than 89 days");
    }
    function test_Critical_UnsustainableRewardModel() public {
        console2.log("=== UNSUSTAINABLE REWARD MODEL ===");
        
        // Simulate multiple users depositing and withdrawing
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2; 
        users[2] = user3;
        
        uint256 depositAmount = 1000 * 10**18;
        uint256 contractInitialBalance = token.balanceOf(address(savings));
        
        console2.log("Initial contract balance:", contractInitialBalance / 10**18, "tokens");
        
        // User 1 deposits and waits 90 days
        vm.startPrank(user1);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        vm.stopPrank();
        // User 2 deposits and waits 90 days
        vm.startPrank(user2);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        vm.stopPrank();
        // User 3 deposits and waits 90 days
        vm.startPrank(user3);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + 90 days);
        
        // User 1 withdraws with rewards
        vm.prank(user1);
        savings.withdraw(0);
        
        uint256 user1Received = token.balanceOf(user1) - (type(uint128).max - depositAmount);
        uint256 contractBalanceAfterUser1 = token.balanceOf(address(savings));
        
        console2.log("User 1 received:", user1Received / 10**18, "tokens");
        console2.log("Contract balance after User 1:", contractBalanceAfterUser1 / 10**18, "tokens");
        // User 2 withdraws with rewards
        vm.prank(user2);
        savings.withdraw(0);
        uint256 user2Received = token.balanceOf(user2) - (type(uint128).max - depositAmount);
        uint256 contractBalanceAfterUser2 = token.balanceOf(address(savings));
        
        console2.log("User 2 received:", user2Received / 10**18, "tokens");
        console2.log("Contract balance after User 2:", contractBalanceAfterUser2 / 10**18, "tokens");
        
        
        // Contract may not have enough tokens to pay back even the principal
        uint256 contractBalance = token.balanceOf(address(savings));
        if (contractBalance < depositAmount) {
            console2.log("CONTRACT INSOLVENT: Cannot even return principal to User 2");
            // This will revert due to insufficient balance
            vm.expectRevert("Insufficient balance");
            vm.prank(user3);
            savings.withdraw(0);
        }
        
    }
    function test_bug9_UnclaimablePenaltyFees() public {
        console2.log("=== UNCLAIMED PENALTY FEES PROBLEM ===");
        
        uint256 depositAmount = 1000 * 10**18; // 1000 tokens
        uint256 expectedPenalty = (depositAmount * EARLY_PENALTY_RATE) / BASIS_POINTS; // 100 tokens
        
        // User deposits
        vm.startPrank(user1);
        token.approve(address(savings), depositAmount);
        savings.deposit(depositAmount);
        
        uint256 contractBalanceBefore = token.balanceOf(address(savings));
        console2.log("Contract balance before early withdrawal:", contractBalanceBefore / 10**18, "tokens");
        
        // User withdraws early (within 60 days)
        vm.warp(block.timestamp + 30 days); // Only 30 days passed
        
        uint256 userBalanceBefore = token.balanceOf(user1);
        savings.withdraw(0);
        uint256 userBalanceAfter = token.balanceOf(user1);
        
        uint256 userReceived = userBalanceAfter - userBalanceBefore;
        uint256 contractBalanceAfter = token.balanceOf(address(savings));
        
        console2.log("User received:", userReceived / 10**18, "tokens");
        console2.log("Expected penalty:", expectedPenalty / 10**18, "tokens");
        console2.log("Contract balance after:", contractBalanceAfter / 10**18, "tokens");
        
        // Verify penalty was collected but not distributed
        uint256 actualPenalty = contractBalanceAfter;
        assertEq(actualPenalty, expectedPenalty, "Penalty should remain in contract");
        assertEq(userReceived, depositAmount - expectedPenalty, "User should receive amount minus penalty");
        
        vm.stopPrank();
        
        // Demonstrate no way to claim penalty
        console2.log("\n=== TRYING TO CLAIM PENALTIES ===");
        
        // Owner tries emergencyWithdraw (this would take penalty fees too)
        uint256 ownerBalanceBefore = token.balanceOf(owner);
        vm.prank(owner);
        savings.emergencyWithdraw(); // This is the only way, but it's an emergency function
        uint256 ownerBalanceAfter = token.balanceOf(owner);
        
        console2.log("Owner received via emergency:", (ownerBalanceAfter - ownerBalanceBefore) / 10**18, "tokens");
        console2.log("This includes penalty fees, but emergency withdraw is not intended for fee collection");
    }
}

// Mock USDT-like token that doesn't return boolean
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply = 1000000 * 10**18;
    
    function transfer(address to, uint256 amount) external {
        // Note: No return value, just like USDT
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
    
    function transferFrom(address from, address to, uint256 amount) external {
        // Note: No return value, just like USDT
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

