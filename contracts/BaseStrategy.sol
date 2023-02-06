// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

abstract contract BaseStrategy is ERC20 {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Reported(
        uint256 indexed profit,
        uint256 indexed loss,
        uint256 indexed fees
    );

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ERC20 public immutable asset;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalDebt;
    uint256 public totalIdle;
    address public management;
    uint256 public lastReport;
    uint256 public maxReportDelay;
    address public treasury;
    uint256 public performanceFee;

    uint256 public fullProfitUnlockDate;
    uint256 public profitUnlockingRate;

    modifier onlyManagement() {
        _onlyManagement();
        _;
    }

    function _onlyManagement() internal view {
        require(msg.sender == management, "not vault");
    }

    // TODO: Add support for non 18 decimal assets
    constructor(
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        asset = _asset;
        management = msg.sender;

        maxReportDelay = 10 days;
        lastReport = block.timestamp;
    }

    function totalAssets() public view returns (uint256) {
        return totalIdle + totalDebt;
    }

    // TODO: Make non-reentrant for all 4 deposit/withdraw functions

    function deposit(uint256 assets, address receiver)
        public
        virtual
        returns (uint256 shares)
    {
        // check lower than max
        require(
            assets <= _maxDeposit(receiver),
            "ERC4626: deposit more than max"
        );
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        // mint
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // invest if applicable
        uint256 invested = _invest(assets);

        // adjust total Assets
        totalDebt += invested;
        totalIdle += (invested - assets);
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        returns (uint256 assets)
    {
        require(shares <= _maxMint(receiver), "ERC4626: mint more than max");

        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // invest if applicable
        uint256 invested = _invest(assets);

        // adjust total Assets
        totalDebt += invested;
        totalIdle += (invested - assets);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual returns (uint256 shares) {
        require(
            assets <= _maxWithdraw(owner),
            "ERC4626: withdraw more than max"
        );

        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 idle = totalIdle;
        uint256 withdrawn = idle >= assets ? _withdraw(assets) : 0;

        _burn(owner, shares);

        totalIdle -= idle > assets ? assets : idle;
        totalDebt -= withdrawn;

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual returns (uint256 assets) {
        require(shares <= _maxRedeem(owner), "ERC4626: redeem more than max");

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        // withdraw if we dont have enough idle
        uint256 idle = totalIdle;
        uint256 withdrawn = idle >= assets ? _withdraw(assets) : 0;

        _burn(owner, shares);

        // adjust state variables
        totalIdle -= idle > assets ? assets : idle;
        totalDebt -= withdrawn;

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // TODO: add locked shares or locked profit calculations based on how profits will be locked

    // TODO: import V3 type logic for reporting profits
    function report()
        external
        onlyManagement
        returns (uint256 profit, uint256 loss)
    {
        // burn unlocked shares
        _burnUnlockedShares();

        // calculate profit
        uint256 invested = _totalInvested();
        uint256 debt = totalDebt;

        if (invested >= debt) {
            profit = invested - debt;
            debt += profit;
        } else {
            loss = debt - invested;
            debt -= loss;
        }

        // TODO: healthcheck ?

        uint256 fees;
        uint256 sharesToLock;
        // only assess fees and lock shares if we have a profit
        if (profit > 0) {
            // asses fees
            fees = (profit * performanceFee) / MAX_BPS;
            // TODO: add a max percent to take?
            // dont take more than the profit
            if (fees > profit) fees = profit;

            // issue all new shares to self
            sharesToLock = convertToShares(profit - fees);
            uint256 feeShares = convertToShares(fees);

            // send shares to treasury
            _mint(treasury, feeShares);

            // mint the rest of profit to self for locking
            _mint(address(this), sharesToLock);
        }

        // lock (profit - fees) of shares issued
        uint256 remainingTime;
        uint256 _fullProfitUnlockDate = fullProfitUnlockDate;
        if (_fullProfitUnlockDate > block.timestamp) {
            remainingTime = _fullProfitUnlockDate - block.timestamp;
        }

        // Update unlocking rate and time to fully unlocked
        uint256 previouslyLockedShares = balanceOf(address(this));
        uint256 totalLockedShares = previouslyLockedShares + sharesToLock;
        uint256 _profitMaxUnlockTime = maxReportDelay;
        if (totalLockedShares > 0 && _profitMaxUnlockTime > 0) {
            // new_profit_locking_period is a weighted average between the remaining time of the previously locked shares and the PROFIT_MAX_UNLOCK_TIME
            uint256 newProfitLockingPeriod = (previouslyLockedShares *
                remainingTime +
                sharesToLock *
                _profitMaxUnlockTime) / totalLockedShares;
            profitUnlockingRate =
                (totalLockedShares * MAX_BPS_EXTENDED) /
                newProfitLockingPeriod;
            fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need to update last_profit_update or fullProfitUnlockDate
            profitUnlockingRate = 0;
        }

        lastReport = block.timestamp;

        // emit event with info
        emit Reported(profit, loss, fees);

        // invest any free funds
        uint256 newlyInvested = _invest(totalIdle);

        // update storage
        totalDebt = (debt + newlyInvested);
        totalIdle -= newlyInvested;
    }

    function trigger() external view returns (bool) {
        return _trigger();
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: cant override totalSupply() with a call to totalSupply() but cant access _totalSupply
    function vaultSupply() public view returns (uint256) {
        return totalSupply() - _unlockedShares();
    }

    function _unlockedShares() internal view returns (uint256) {
        uint256 _fullProfitUnlockDate = fullProfitUnlockDate;
        uint256 unlockedShares = 0;
        if (_fullProfitUnlockDate > block.timestamp) {
            unlockedShares =
                (profitUnlockingRate * (block.timestamp - lastReport)) /
                MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            unlockedShares = balanceOf(address(this));
        }

        return unlockedShares;
    }

    function _burnUnlockedShares() internal {
        uint256 unlcokdedShares = _unlockedShares();
        if (unlcokdedShares == 0) {
            return;
        }

        // TODO: this doesnt
        // update variables (done here to keep _unlcokdedShares() as a view function)
        if (fullProfitUnlockDate <= block.timestamp) {
            profitUnlockingRate = 0;
        }

        _burn(address(this), unlcokdedShares);
    }

    function convertToShares(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = vaultSupply(); // Saves an extra SLOAD if vaultSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Down);
    }

    function convertToAssets(uint256 shares)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = vaultSupply(); // Saves an extra SLOAD if vaultSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Down);
    }

    function previewDeposit(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = vaultSupply(); // Saves an extra SLOAD if vaultSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = vaultSupply(); // Saves an extra SLOAD if vaultSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares)
        public
        view
        virtual
        returns (uint256)
    {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT/WITHDRAWAL LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address _owner)
        external
        view
        virtual
        returns (uint256)
    {
        return _maxDeposit(_owner);
    }

    function maxMint(address _owner) external view virtual returns (uint256) {
        return _maxMint(_owner);
    }

    function maxWithdraw(address _owner)
        external
        view
        virtual
        returns (uint256)
    {
        return _maxWithdraw(_owner);
    }

    function maxRedeem(address _owner) external view virtual returns (uint256) {
        return _maxRedeem(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                    NEEDED TO OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // Will attempt to free the 'amount' of assets and return the acutal amount
    function _withdraw(uint256 amount)
        internal
        virtual
        returns (uint256 withdrawnAmount);

    // will invest up to the amount of 'assets' and return the actual amount that was invested
    function _invest(uint256 assets)
        internal
        virtual
        returns (uint256 invested);

    // internal non-view function to return the accurate amount of funds currently invested
    // should do any needed accrual etc. before returning the the amount invested
    function _totalInvested() internal virtual returns (uint256);

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    function _trigger() internal view virtual returns (bool) {
        if (!_isBaseFeeAcceptable()) {
            return block.timestamp - lastReport > maxReportDelay;
        }
    }

    function _tend() internal virtual {}

    function _maxDeposit(address) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    function _maxMint(address) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    function _maxWithdraw(address owner)
        internal
        view
        virtual
        returns (uint256)
    {
        return convertToAssets(balanceOf(owner));
    }

    function _maxRedeem(address owner) internal view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }
}
