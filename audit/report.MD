# Security Audit Report: TimeLockSavings Contract

## Executive Summary

This report presents a comprehensive security analysis of the TimeLockSavings contract and its associated test suite. The analysis identified 7 distinct vulnerabilities ranging from **Medium** to **Low** severity. The most critical issues involve incorrect parameter ordering in reward calculations, potential token compatibility problems that could lead to contract failures with certain ERC20 tokens and unfair reward distribution due to time-based "Cliffs"

---

## Findings

### **Finding 1: Incorrect Parameter Order in Reward Calculation**
**Severity: MEDIUM**

#### Description
The `withdraw()` function calls `calculateReward()` with parameters in the wrong order, passing `timeElapsed` first and `amount` second, while the function expects `amount` first and `timeElapsed` second.

#### Root Cause
```solidity
// Line 67 in TimeLockSavings.sol
uint256 reward = calculateReward(timeElapsed, amount); // Wrong order

// Function signature expects:
function calculateReward(uint256 _amount, uint256 _timeElapsed) public pure returns (uint256)
```

#### Impact
- **Incorrect reward calculations** for all normal withdrawals
- For typical scenarios where `timeElapsed` (in seconds) is much larger than `amount` (in wei), users receive significantly inflated rewards
- Example: 1000 tokens locked for 60 days should yield ~20 tokens reward, but yields ~5,184,000 tokens due to parameter swap
- **Economic impact**: Severe over-payment of rewards leading to contract fund depletion

#### Proof of Concept
```solidity
function test_bug1_WrongParameterOrder_BasicCase() public {
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
```

#### Mitigation
```solidity
// Fix line 67
uint256 reward = calculateReward(amount, timeElapsed); // Correct order
```

---

### **Finding 2: ERC20 Token Compatibility Issue**
**Severity: MEDIUM**

#### Description
The contract uses direct `transfer()` and `transferFrom()` calls instead of safe variants, making it incompatible with tokens like USDT that don't return boolean values on success.

#### Root Cause
```solidity
// Lines with compatibility issues:
require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed"); // Line 42
require(token.transfer(msg.sender, withdrawAmount), "Transfer failed"); // Line 58
require(token.transfer(msg.sender, totalAmount), "Transfer failed"); // Line 70
require(token.transfer(owner, balance), "Transfer failed"); // Line 108
```

#### Impact
- **Contract failure** with non-standard ERC20 tokens (USDT, BNB, OMG, etc.)
- These tokens don't return boolean values, causing `require()` statements to fail
- **Complete contract unusability** with affected tokens despite successful transfers

#### Proof of Concept
```solidity
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
```

#### Mitigation
Implement SafeERC20 wrapper or custom safe transfer functions:
```solidity
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TimeLockSavings {
    using SafeERC20 for IERC20;
    
    // Replace all token.transfer() with:
    token.safeTransfer(recipient, amount);
    
    // Replace all token.transferFrom() with:
    token.safeTransferFrom(sender, recipient, amount);
}
```

---

### **Finding 3: Unfair Reward Distribution Due to Time-Based "Cliffs"**
**Severity: MEDIUM**

#### Description
The reward calculation uses discrete 30-day bonus periods, creating unfair "cliffs" where users receive no additional rewards for locking funds for periods just shy of the next bonus threshold.

#### Root Cause
```solidity
// Lines 84-88 in TimeLockSavings.sol
if (_timeElapsed > MIN_LOCK_PERIOD) {
    uint256 extraPeriods = (_timeElapsed - MIN_LOCK_PERIOD) / BONUS_PERIOD;
    uint256 bonusReward = (_amount * BONUS_REWARD_RATE * extraPeriods) / BASIS_POINTS;
    reward += bonusReward;
}
```
Integer division means any extra time less than a full 30-day period results in zero bonus reward.

#### Impact
- **Unfair user experience**: Users locking funds for 89 days receive the same reward as those locking for 60 days
- **Perverse incentives**: Encourages users to time withdrawals exactly at 30-day intervals
- **Economic inefficiency**: Does not properly reward users for partial locking periods

#### Proof of Concept
```solidity
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
                reward2 / 10**18, "to", 
                reward3 / 10**18);
    
    assertTrue(reward3 > reward2, "Should get more reward after threshold");
    assertEq(reward3 - reward2, 10 * 10**18, "Should get exactly 10 token bonus at cliff");
    
    // This demonstrates the unfairness: 89 days gets same reward as 60 days!
    uint256 reward60Days = savings.calculateReward(depositAmount, minLock);
    assertEq(reward1, reward60Days, "89 days gets same reward as 60 days (UNFAIR!)");
    assertTrue(reward3 > reward1, "90 days should get more than 89 days");
}
```

#### Mitigation
Implement a continuous reward calculation that proportionally rewards users based on the exact time locked:
```solidity
if (_timeElapsed > MIN_LOCK_PERIOD) {
    uint256 extraTime = _timeElapsed - MIN_LOCK_PERIOD;
    uint256 bonusReward = (_amount * BONUS_REWARD_RATE * extraTime) / (BONUS_PERIOD * BASIS_POINTS);
    reward += bonusReward;
}
```

---

### **Finding 4: Event Parameter Order Mismatch**
**Severity: LOW**

#### Description
The `Deposited` event is emitted with parameters in wrong order compared to its declaration.

#### Root Cause
```solidity
// Event declaration
event Deposited(address indexed user, uint256 amount, uint256 depositId);

// Emission (Line 47)
emit Deposited(msg.sender, userDeposits[msg.sender].length - 1, _amount);
//              ^user       ^depositId                           ^amount
```

#### Impact
- **Off-chain monitoring tools** may misinterpret event data
- **Frontend applications** parsing events will receive incorrect parameter mapping
- **Data analytics** based on events will be inaccurate

#### Proof of Concept
```solidity
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
```

#### Mitigation
```solidity
// Fix emission order
emit Deposited(msg.sender, _amount, userDeposits[msg.sender].length - 1);
```

---

### **Finding 5: Incomplete State Cleanup After Withdrawal**
**Severity: LOW**

#### Description
After withdrawal, the deposit's `amount` field remains unchanged while only the `withdrawn` flag is set to true, leading to inconsistent state.

#### Root Cause
```solidity
// In withdraw() function, only withdrawn flag is updated:
userDeposit.withdrawn = true;
// amount field remains unchanged
```

#### Impact
- **Inconsistent contract state** where withdrawn deposits show non-zero amounts
- **Potential confusion** in off-chain systems reading contract state
- **Storage inefficiency** maintaining unnecessary data

#### Proof of Concept
```solidity
function test_bug3_DepositStateAfterWithdrawal() public {
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
```

#### Mitigation
```solidity
// After marking as withdrawn, clear the amount
userDeposit.withdrawn = true;
userDeposit.amount = 0; // Add this line
```

---

### **Finding 6: Precision Loss in Reward Calculations**
**Severity: LOW**

#### Description
Small deposit amounts suffer from precision loss due to integer division, resulting in zero rewards even when mathematically they should receive some reward.

#### Root Cause
```solidity
// Line 80
uint256 reward = (_amount * BASE_REWARD_RATE) / BASIS_POINTS;
// For amounts < 50 wei, this results in 0 due to integer division
```

#### Impact
- **Users with small deposits receive no rewards** despite meeting lock period requirements
- **Unfair treatment** for small depositors
- **Minimum threshold** of ~50 wei required to receive any reward (50 * 200 / 10000 = 1)

#### Proof of Concept
```solidity
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
```

#### Mitigation
Consider implementing a minimum deposit amount or using a more precision-preserving calculation method:
```solidity
require(_amount >= BASIS_POINTS / BASE_REWARD_RATE, "Amount too small for rewards");
```

---

### **Finding 7: Missing Constructor Input Validation**
**Severity: LOW**

#### Description
The constructor accepts zero address for the token parameter without validation, creating a non-functional contract.

#### Root Cause
```solidity
constructor(address _token) {
    token = IERC20(_token); // No validation for zero address
    owner = msg.sender;
}
```

#### Impact
- **Deployment with invalid token address** creates unusable contract
- **Deployment costs wasted** on non-functional contract
- **No recovery mechanism** due to immutable token address

#### Proof of Concept
```solidity
function test_bug5_ConstructorNoValidation() public {
    // This should ideally fail but currently doesn't
    TimeLockSavings invalidSavings = new TimeLockSavings(address(0));
    
    // Verify the contract was created with zero address
    assertEq(address(invalidSavings.token()), address(0), "Contract accepts zero address token");
    
    // This makes the contract non-functional
    // Any attempt to use it would fail in token operations
}
```

#### Mitigation
```solidity
constructor(address _token) {
    require(_token != address(0), "Invalid token address");
    token = IERC20(_token);
    owner = msg.sender;
}
```

---

## Summary

| Finding | Severity | Status |
|---------|----------|--------|
| Incorrect Parameter Order in Reward Calculation | MEDIUM | Needs Fix |
| ERC20 Token Compatibility Issue | MEDIUM | Needs Fix |
| Unfair Reward Distribution Due to Time-Based "Cliffs" | MEDIUM |Needs Fix |
| Event Parameter Order Mismatch | LOW | Recommended Fix |
| Incomplete State Cleanup After Withdrawal | LOW | Recommended Fix |
| Precision Loss in Reward Calculations | LOW | Consider Fix |
| Missing Constructor Input Validation | LOW | Recommended Fix |

## Recommendations

1. **Immediate Action Required**: Fix the parameter order bug in reward calculation as this has severe economic impact
2. **High Priority**: Implement SafeERC20 to ensure compatibility with all ERC20 tokens
3. **Address reward fairness**: Implement continuous reward calculation to eliminate time-based cliffs
4. **Code Quality**: Fix event parameter order and state cleanup issues
5. **Consider**: Implement minimum deposit amounts and constructor validation

The contract shows good overall structure and logic, but these issues should be addressed before production deployment to ensure security, compatibility, and correct functionality.