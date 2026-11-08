// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BBATestMining
 * @notice Standalone TEST ERC20 with burn-powered weekly mining and deferred fee swaps.
 * @dev Prototype: deploy on a test chain, establish liquidity, and audit before mainnet.
 *      No proxy, delegatecall, arbitrary minting by owner, or upgrade hooks.
 */
interface IV2RouterLike {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external;
}

contract BBATestMining {
    string public constant name = "BBA TEST";
    string public constant symbol = "TEST";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant WEEK = 7 days;
    uint256 private constant BPS = 10_000;
    uint256 public constant SWAP_THRESHOLD = 1_000 ether;

    address public owner;
    address public dao;
    address public immutable usdt;
    IV2RouterLike public immutable router;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Configurable transfer fee is separate from the chart's withdrawal fee.
    uint256 public transferFeeBps = 300; // 3%, maximum 5%
    uint256 public maxSlippageBps = 300; // 3%, maximum 10%
    uint256 public minimumUsdtOut; // optional absolute execution floor in USDT base units
    mapping(address => bool) public feeExempt;
    bool public swapEnabled = true;
    bool private swapping;
    bool private entered;
    address[] private swapPath;

    mapping(address => uint256) public power;
    mapping(address => uint256) public lastMint;
    mapping(address => address) public referrer;
    mapping(address => bool) public referralBound;
    uint256 public totalBurned;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DAOChanged(address indexed oldDAO, address indexed newDAO);
    event BurnForPower(address indexed miner, uint256 burned, uint256 powerAdded);
    event MiningMint(address indexed miner, uint256 weeksClaimed, uint256 reward, uint256 newPower);
    event ReferralBound(address indexed user, address indexed parent);
    event ReferralPower(address indexed beneficiary, address indexed miner, uint256 added, uint8 level);
    event FeeConfigChanged(uint256 feeBps, uint256 slippageBps, bool enabled);
    event SwapPathChanged(address[] path);
    event FeesSold(uint256 testInput, uint256 usdtReceived);
    event FeesSwapSkipped(uint256 testAmount, bytes reason);

    error Unauthorized();
    error BadAddress();
    error BadValue();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ReentrantCall();
    error NotReady();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /**
     * @param dao_ USDT beneficiary.
     * @param router_ UniswapV2-compatible router, must support fee-on-transfer swaps.
     * @param usdt_ Actual USDT contract on target chain.
     * @param intermediate_ Wrapped native asset (e.g. WQKI), or zero for direct TEST/USDT.
     */
    constructor(address dao_, address router_, address usdt_, address intermediate_) {
        if (dao_ == address(0) || router_ == address(0) || usdt_ == address(0)) revert BadAddress();
        if (router_.code.length == 0 || usdt_.code.length == 0) revert BadAddress();
        owner = msg.sender;
        dao = dao_;
        router = IV2RouterLike(router_);
        usdt = usdt_;
        feeExempt[msg.sender] = true;
        feeExempt[address(this)] = true;
        feeExempt[dao_] = true;

        swapPath.push(address(this));
        if (intermediate_ != address(0)) {
            if (intermediate_ == usdt_ || intermediate_ == address(this)) revert BadAddress();
            swapPath.push(intermediate_);
        }
        swapPath.push(usdt_);
        _mint(msg.sender, INITIAL_SUPPLY);
        emit OwnershipTransferred(address(0), msg.sender);
        emit SwapPathChanged(swapPath);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert BadAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert BadAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        uint256 tax = (!swapping && !feeExempt[from] && !feeExempt[to])
            ? (amount * transferFeeBps / BPS) : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - tax;
        emit Transfer(from, to, amount - tax);
        if (tax != 0) {
            balanceOf[address(this)] += tax;
            emit Transfer(from, address(this), tax);
        }
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // Explicit power accounting: burning 1 TEST produces 3 power units.
    function burn(uint256 amount) external nonReentrant {
        if (amount == 0 || balanceOf[msg.sender] < amount) revert BadValue();
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        totalBurned += amount;
        power[msg.sender] += 3 * amount;
        if (lastMint[msg.sender] == 0) lastMint[msg.sender] = block.timestamp;
        emit Transfer(msg.sender, address(0), amount);
        emit BurnForPower(msg.sender, amount, 3 * amount);
    }

    function bindReferrer(address parent) external {
        if (referralBound[msg.sender] || parent == address(0) || parent == msg.sender
            || referrer[parent] == msg.sender) revert BadValue();
        // Only bind before mining begins to prevent moving referral branches.
        if (power[msg.sender] != 0 || lastMint[msg.sender] != 0) revert BadValue();
        // Forbid referral cycles and cap ancestry depth for predictable gas use.
        address cursor = parent;
        for (uint256 i = 0; i < 32 && cursor != address(0); ++i) {
            if (cursor == msg.sender) revert BadValue();
            cursor = referrer[cursor];
            if (i == 31 && cursor != address(0)) revert BadValue();
        }
        referralBound[msg.sender] = true;
        referrer[msg.sender] = parent;
        emit ReferralBound(msg.sender, parent);
    }

    /**
     * @notice Rates/bonus amounts follow the chart. Rates are weekly.
     * Tier: power < 5k / 5k-50k / 50k-100k / 100k-200k / 200k-400k / >=400k.
     */
    function tierInfo(uint256 p) public pure returns (
        uint8 tier, uint256 weeklyRateBps, uint256 firstBonusBps, uint256 secondBonusBps,
        uint256 withdrawalFeeBps
    ) {
        if (p < 5_000 ether) return (0, 45, 300, 50, 3500);
        if (p < 50_000 ether) return (1, 50, 400, 100, 3000);
        if (p < 100_000 ether) return (2, 55, 500, 200, 2500);
        if (p < 200_000 ether) return (3, 60, 600, 300, 2000);
        if (p < 400_000 ether) return (4, 65, 700, 400, 1500);
        return (5, 70, 800, 500, 1000);
    }

    function pendingReward(address miner) public view returns (uint256 reward, uint256 weeksDue) {
        uint256 start = lastMint[miner];
        if (start == 0 || power[miner] == 0 || block.timestamp < start + WEEK) return (0, 0);
        weeksDue = (block.timestamp - start) / WEEK;
        if (weeksDue > 5) weeksDue = 5; // maximum five weeks collected per claim
        (, uint256 rate,,,) = tierInfo(power[miner]);
        reward = power[miner] * rate * weeksDue / BPS;
    }

    /**
     * @notice Claims mined TEST. Sells at most 1000 accumulated TEST fees to USDT/DAO.
     * @dev Swap fails open: if liquidity, quote, or trade fails, mint still succeeds.
     *      Individual weekly claim is limited to five weeks; longer unclaimed periods expire.
     */
    function mint() external nonReentrant {
        (uint256 reward, uint256 weeksDue) = pendingReward(msg.sender);
        if (weeksDue == 0 || reward == 0) revert NotReady();
        uint256 currentPower = power[msg.sender];
        (, , uint256 firstBps, uint256 secondBps,) = tierInfo(currentPower);
        lastMint[msg.sender] = block.timestamp;
        _mint(msg.sender, reward);

        // CCT-style referral bonuses are credited to referral power, not token balances.
        address parent = referrer[msg.sender];
        if (parent != address(0)) {
            uint256 firstPower = reward * firstBps / BPS;
            power[parent] += firstPower;
            if (lastMint[parent] == 0) lastMint[parent] = block.timestamp;
            emit ReferralPower(parent, msg.sender, firstPower, 1);
            address grandparent = referrer[parent];
            if (grandparent != address(0)) {
                uint256 secondPower = reward * secondBps / BPS;
                power[grandparent] += secondPower;
                if (lastMint[grandparent] == 0) lastMint[grandparent] = block.timestamp;
                emit ReferralPower(grandparent, msg.sender, secondPower, 2);
            }
        }
        emit MiningMint(msg.sender, weeksDue, reward, currentPower);
        _trySwapFees();
    }

    function _trySwapFees() internal {
        if (!swapEnabled || swapping || balanceOf[address(this)] < SWAP_THRESHOLD) return;
        uint256 amount = SWAP_THRESHOLD;
        address[] memory path = swapPath;
        uint256 quoted;
        try router.getAmountsOut(amount, path) returns (uint256[] memory amounts) {
            if (amounts.length != path.length) {
                emit FeesSwapSkipped(amount, bytes("INVALID_QUOTE"));
                return;
            }
            quoted = amounts[amounts.length - 1];
        } catch (bytes memory reason) {
            emit FeesSwapSkipped(amount, reason);
            return;
        }
        uint256 minimum = quoted * (BPS - maxSlippageBps) / BPS;
        if (minimum == 0 || minimum < minimumUsdtOut) {
            emit FeesSwapSkipped(amount, bytes("LOW_QUOTE"));
            return;
        }

        swapping = true;
        allowance[address(this)][address(router)] = amount;
        emit Approval(address(this), address(router), amount);
        uint256 beforeDao = _usdtBalance(dao);
        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, minimum, path, dao, block.timestamp + 120
        ) {
            uint256 afterDao = _usdtBalance(dao);
            emit FeesSold(amount, afterDao >= beforeDao ? afterDao - beforeDao : 0);
        } catch (bytes memory reason) {
            emit FeesSwapSkipped(amount, reason);
        }
        allowance[address(this)][address(router)] = 0;
        emit Approval(address(this), address(router), 0);
        swapping = false;
    }

    function _usdtBalance(address account) internal view returns (uint256 result) {
        (bool ok, bytes memory data) = usdt.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (ok && data.length >= 32) result = abi.decode(data, (uint256));
    }

    function getSwapPath() external view returns (address[] memory) { return swapPath; }
    function accumulatedFees() external view returns (uint256) { return balanceOf[address(this)]; }

    function setDAO(address newDao) external onlyOwner {
        if (newDao == address(0)) revert BadAddress();
        emit DAOChanged(dao, newDao);
        dao = newDao;
        feeExempt[newDao] = true;
    }

    function setTransferFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 500) revert BadValue(); // 0..5%
        transferFeeBps = newBps;
        emit FeeConfigChanged(transferFeeBps, maxSlippageBps, swapEnabled);
    }

    function setSwapConfig(uint256 slippageBps, uint256 usdtFloor, bool enabled) external onlyOwner {
        if (slippageBps > 1_000) revert BadValue(); // maximum 10%
        maxSlippageBps = slippageBps;
        minimumUsdtOut = usdtFloor;
        swapEnabled = enabled;
        emit FeeConfigChanged(transferFeeBps, maxSlippageBps, enabled);
    }

    function setSwapIntermediate(address intermediate) external onlyOwner {
        if (intermediate == address(this) || intermediate == usdt) revert BadAddress();
        delete swapPath;
        swapPath.push(address(this));
        if (intermediate != address(0)) swapPath.push(intermediate);
        swapPath.push(usdt);
        emit SwapPathChanged(swapPath);
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0) || account == address(this)) revert BadAddress();
        feeExempt[account] = exempt;
    }

    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert BadAddress();
        emit OwnershipTransferred(owner, nextOwner);
        owner = nextOwner;
    }
}