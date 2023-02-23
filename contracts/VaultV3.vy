# @version 0.3.7

from vyper.interfaces import ERC20
from vyper.interfaces import ERC20Detailed

# INTERFACES #
interface IStrategy:
    def asset() -> address: view
    def balanceOf(owner: address) -> uint256: view
    def maxDeposit(receiver: address) -> uint256: view
    def maxWithdraw(owner: address) -> uint256: view
    def withdraw(amount: uint256, receiver: address, owner: address) -> uint256: nonpayable
    def deposit(assets: uint256, receiver: address) -> uint256: nonpayable
    def totalAssets() -> (uint256): view
    def convertToAssets(shares: uint256) -> (uint256): view
    def convertToShares(assets: uint256) -> (uint256): view

interface IAccountant:
    def report(strategy: address, gain: uint256, loss: uint256) -> (uint256, uint256): nonpayable

interface IQueueManager:
    def withdraw_queue(vault: address) -> (DynArray[address, 10]): nonpayable
    def should_override(vault: address) -> (bool): nonpayable
    def new_strategy(strategy: address): nonpayable
    def remove_strategy(strategy: address): nonpayable

interface IFactory:
    def protocol_fee_config() -> (uint16, uint32, address): view

# EVENTS #
# ERC4626 EVENTS
event Deposit:
    sender: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256

event Withdraw:
    sender: indexed(address)
    receiver: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256

# ERC20 EVENTS
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

# STRATEGY EVENTS
event StrategyChanged:
    strategy: indexed(address)
    change_type: indexed(StrategyChangeType)
    
event StrategyReported:
    strategy: indexed(address)
    gain: uint256
    loss: uint256
    current_debt: uint256
    protocol_fees: uint256
    total_fees: uint256
    total_refunds: uint256

# DEBT MANAGEMENT EVENTS
event DebtUpdated:
    strategy: indexed(address)
    current_debt: uint256
    new_debt: uint256

# STORAGE MANAGEMENT EVENTS
event UpdateAccountant:
    accountant: indexed(address)

event UpdateQueueManager:
    queue_manager: indexed(address)

event UpdatedMaxDebtForStrategy:
    sender: indexed(address)
    strategy: indexed(address)
    new_debt: uint256

event UpdateDepositLimit:
    deposit_limit: uint256

event UpdateMinimumTotalIdle:
    minimum_total_idle: uint256

event UpdateProfitMaxUnlockTime:
    profit_max_unlock_time: uint256

event Shutdown:
    pass

event Sweep:
    token: indexed(address)
    amount: uint256

# STRUCTS #
struct StrategyParams:
    activation: uint256
    last_report: uint256
    current_debt: uint256
    max_debt: uint256

# CONSTANTS #
MAX_BPS: constant(uint256) = 10_000
MAX_BPS_EXTENDED: constant(uint256) = 1_000_000_000_000
PROTOCOL_FEE_ASSESSMENT_PERIOD: constant(uint256) = 24 * 3600 # assess once a day
API_VERSION: constant(String[28]) = "0.1.0"

# ENUMS #
# Each permissioned function has its own Role.
# Roles can be combined in any combination or all kept seperate.
# Follows python Enum patterns so the first role == 1 and doubles each time.
enum Roles:
    ADD_STRATEGY_MANAGER # can add strategies to the vault
    REVOKE_STRATEGY_MANAGER # can remove strategies from the vault
    FORCE_REVOKE_MANAGER # can force revoke a strategy causing a loss
    ACCOUNTANT_MANAGER # can set the accountant that assesss fees
    QUEUE_MANAGER # can set the queue manager
    REPORTING_MANAGER # calls report for a strategy
    DEBT_MANAGER # adds and remove debt from strategies
    MAX_DEBT_MANAGER # can set the max debt for a strategy
    DEPOSIT_LIMIT_MANAGER # sets deposit limit for the vault
    MINIMUM_IDLE_MANAGER # sets the minimun total idle the vault should keep
    PROFIT_UNLOCK_MANAGER # sets the profit_max_unlock_time
    SWEEPER # can sweep tokens from the vault
    EMERGENCY_MANAGER # can shutdown vault in an emergency

enum StrategyChangeType:
    ADDED
    REVOKED

# IMMUTABLE #
ASSET: immutable(ERC20)
DECIMALS: immutable(uint256)
FACTORY: public(immutable(address))

# STORAGE #
# HashMap that records all the strategies that are allowed to receive assets from the vault
strategies: public(HashMap[address, StrategyParams])
# ERC20 - amount of shares per account
balance_of: HashMap[address, uint256]
# ERC20 - owner -> (spender -> amount)
allowance: public(HashMap[address, HashMap[address, uint256]])

# Total amount of shares that are currently minted
total_supply: public(uint256)

# Total amount of assets that has been deposited in strategies
total_debt: public(uint256)
# Current assets held in the vault contract. Replacing balanceOf(this) to avoid price_per_share manipulation
total_idle: public(uint256)
# Minimum amount of assets that should be kept in the vault contract to allow for fast, cheap redeems
minimum_total_idle: public(uint256)
# Maximum amount of tokens that the vault can accept. If totalAssets > deposit_limit, deposits will revert
deposit_limit: public(uint256)
accountant: public(address)
queue_manager: public(address)
# HashMap mapping addresses to their roles
roles: public(HashMap[address, Roles])
# HashMap mapping roles to their permissioned state. If false, the role is not open to the public
open_roles: public(HashMap[Roles, bool])
# Address that can add and remove addresses to roles 
role_manager: public(address)
# Temporary variable to store the address of the next role_manager until the role is accepted
future_role_manager: public(address)
# State of the vault - if set to true, only withdrawals will be available. It can't be reverted
shutdown: public(bool)

# ERC20 - name of the token
name: public(String[64])
# ERC20 - symbol of the token
symbol: public(String[32])

profit_max_unlock_time: public(uint256)
full_profit_unlock_date: public(uint256)
profit_unlocking_rate: public(uint256)
last_profit_update: uint256

last_report: public(uint256)

# `nonces` track `permit` approvals with signature.
nonces: public(HashMap[address, uint256])
DOMAIN_TYPE_HASH: constant(bytes32) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
PERMIT_TYPE_HASH: constant(bytes32) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")

# Constructor
@external
def __init__(asset: ERC20, name: String[64], symbol: String[32], role_manager: address, profit_max_unlock_time: uint256):
    ASSET = asset
    DECIMALS = convert(ERC20Detailed(asset.address).decimals(), uint256)
    assert 10 ** (2 * DECIMALS) <= max_value(uint256) # dev: token decimals too high

    FACTORY = msg.sender

    self.profit_max_unlock_time = profit_max_unlock_time
    self.name = name
    self.symbol = symbol
    self.last_report = block.timestamp
    self.role_manager = role_manager
    self.shutdown = False

## SHARE MANAGEMENT ##
## ERC20 ##
@internal
def _spend_allowance(owner: address, spender: address, amount: uint256):
    # Unlimited approval does nothing (saves an SSTORE)
    current_allowance: uint256 = self.allowance[owner][spender]
    if (current_allowance < max_value(uint256)):
        assert current_allowance >= amount, "insufficient allowance"
        self._approve(owner, spender, current_allowance - amount)

@internal
def _transfer(sender: address, receiver: address, amount: uint256):
    assert self.balance_of[sender] >= amount, "insufficient funds"
    self.balance_of[sender] -= amount
    self.balance_of[receiver] += amount
    log Transfer(sender, receiver, amount)

@internal
def _transfer_from(sender: address, receiver: address, amount: uint256) -> bool:
    self._spend_allowance(sender, msg.sender, amount)
    self._transfer(sender, receiver, amount)
    return True

@internal
def _approve(owner: address, spender: address, amount: uint256) -> bool:
    self.allowance[owner][spender] = amount
    log Approval(owner, spender, amount)
    return True

@internal
def _increase_allowance(owner: address, spender: address, amount: uint256) -> bool:
    self.allowance[owner][spender] += amount
    log Approval(owner, spender, self.allowance[owner][spender])
    return True

@internal
def _decrease_allowance(owner: address, spender: address, amount: uint256) -> bool:
    self.allowance[owner][spender] -= amount
    log Approval(owner, spender, self.allowance[owner][spender])
    return True

@internal
def _permit(owner: address, spender: address, amount: uint256, deadline: uint256, v: uint8, r: bytes32, s: bytes32) -> bool:
    assert owner != empty(address), "invalid owner"
    assert deadline >= block.timestamp, "permit expired"
    nonce: uint256 = self.nonces[owner]
    digest: bytes32 = keccak256(
        concat(
            b'\x19\x01',
            self.domain_separator(),
            keccak256(
                concat(
                    PERMIT_TYPE_HASH,
                    convert(owner, bytes32),
                    convert(spender, bytes32),
                    convert(amount, bytes32),
                    convert(nonce, bytes32),
                    convert(deadline, bytes32),
                )
            )
        )
    )
    assert ecrecover(digest, convert(v, uint256), convert(r, uint256), convert(s, uint256)) == owner, "invalid signature"
    self.allowance[owner][spender] = amount
    self.nonces[owner] = nonce + 1
    log Approval(owner, spender, amount)
    return True

@internal
def _burn_shares(shares: uint256, owner: address):
    self.balance_of[owner] -= shares
    self.total_supply -= shares
    log Transfer(owner, empty(address), shares)

@view
@internal
def _unlocked_shares() -> uint256:
    # To avoid sudden price_per_share spikes, profit must be processed through an unlocking period.
    # The mechanism involves shares to be minted to the vault which are unlocked gradually over time.
    # Shares that have been locked are gradually unlocked over profit_max_unlock_time seconds
    _full_profit_unlock_date: uint256 = self.full_profit_unlock_date
    unlocked_shares: uint256 = 0
    if _full_profit_unlock_date > block.timestamp:
        unlocked_shares = self.profit_unlocking_rate * (block.timestamp - self.last_profit_update) / MAX_BPS_EXTENDED
    elif _full_profit_unlock_date != 0:
        # All shares have been unlocked
        unlocked_shares = self.balance_of[self]

    return unlocked_shares

@view
@internal
def _total_supply() -> uint256:
    return self.total_supply - self._unlocked_shares()

@internal
def _burn_unlocked_shares():
    """
    Burns shares that have been unlocked since last update. 
    In case the full unlocking period has passed, it stops the unlocking
    """
    unlocked_shares: uint256 = self._unlocked_shares()
    if unlocked_shares == 0:
        return

    # Only do an SSTORE if necessary
    if self.full_profit_unlock_date > block.timestamp:
        self.last_profit_update = block.timestamp

    self._burn_shares(unlocked_shares, self)

@view
@internal
def _total_assets() -> uint256:
    """
    Total amount of assets that are in the vault and in the strategies. 
    """
    return self.total_idle + self.total_debt

@view
@internal
def _convert_to_assets(shares: uint256) -> uint256:
    """ 
    assets = shares * (total_assets / total_supply) --- (== price_per_share * shares)
    """
    _total_supply: uint256 = self._total_supply()
    # if total_supply is 0, price_per_share is 1
    if _total_supply == 0: 
        return shares

    amount: uint256 = shares * self._total_assets() / _total_supply
    return amount

@view
@internal
def _convert_to_shares(assets: uint256) -> uint256:
    """
    shares = amount * (total_supply / total_assets) --- (== amount / price_per_share)
    """
    total_assets: uint256 = self._total_assets()

    # if total_supply is 0, price_per_share is 1
    if total_assets == 0:
       return assets

    shares: uint256 = assets * self._total_supply() / total_assets
    return shares


@internal
def erc20_safe_approve(token: address, spender: address, amount: uint256):
    # Used only to send tokens that are not the type managed by this Vault.
    # HACK: Used to handle non-compliant tokens like USDT
    response: Bytes[32] = raw_call(
        token,
        concat(
            method_id("approve(address,uint256)"),
            convert(spender, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"


@internal
def erc20_safe_transfer_from(token: address, sender: address, receiver: address, amount: uint256):
    # Used only to send tokens that are not the type managed by this Vault.
    # HACK: Used to handle non-compliant tokens like USDT
    response: Bytes[32] = raw_call(
        token,
        concat(
            method_id("transferFrom(address,address,uint256)"),
            convert(sender, bytes32),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"

@internal
def erc20_safe_transfer(token: address, receiver: address, amount: uint256):
    # Used only to send tokens that are not the type managed by this Vault.
    # HACK: Used to handle non-compliant tokens like USDT
    response: Bytes[32] = raw_call(
        token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"

@internal
def _issue_shares(shares: uint256, recipient: address):
    self.balance_of[recipient] += shares
    self.total_supply += shares

    log Transfer(empty(address), recipient, shares)

@internal
def _issue_shares_for_amount(amount: uint256, recipient: address) -> uint256:
    """
    Issues shares that are worth 'amount' in the underlying token (asset)
    WARNING: this takes into account that any new assets have been summed to total_assets (otherwise pps will go down)
    """
    total_supply: uint256 = self._total_supply()
    total_assets: uint256 = self._total_assets()
    new_shares: uint256 = 0
    
    if total_supply == 0:
        new_shares = amount
    elif total_assets > amount:
        new_shares = amount * self._total_supply() / (total_assets - amount)
    else:
        # after first deposit, getting here would mean that the rest of the shares would be diluted to ~0
        assert total_assets > amount, "amount too high"
  
    # We don't make the function revert
    if new_shares == 0:
       return 0

    self._issue_shares(new_shares, recipient)

    return new_shares

## ERC4626 ##
@view
@internal
def _max_deposit(receiver: address) -> uint256:
    _total_assets: uint256 = self._total_assets()
    _deposit_limit: uint256 = self.deposit_limit
    if (_total_assets >= _deposit_limit):
        return 0

    return _deposit_limit - _total_assets

@view
@internal
def _max_redeem(owner: address) -> uint256:
    # NOTE: this will return the max amount that is available to redeem using ERC4626 (which can only withdraw from the vault contract)
    return min(self.balance_of[owner], self._convert_to_shares(self.total_idle))


@internal
def _deposit(_sender: address, _recipient: address, _assets: uint256) -> uint256:
    assert self.shutdown == False # dev: shutdown
    assert _recipient not in [self, empty(address)], "invalid recipient"
    assets: uint256 = _assets
    # If the amount is max_value(uint256) we assume the user wants to deposit their whole balance
    if assets == max_value(uint256):
        assets = ASSET.balanceOf(_sender)

    assert self._total_assets() + assets <= self.deposit_limit, "exceed deposit limit"
 
    self.erc20_safe_transfer_from(ASSET.address, msg.sender, self, assets)
    self.total_idle += assets
   
    shares: uint256 = self._issue_shares_for_amount(assets, _recipient)
    assert shares > 0, "cannot mint zero"

    log Deposit(_sender, _recipient, assets, shares)

    return shares

@view
@internal
def _assess_share_of_unrealised_losses(strategy: address, assets_needed: uint256) -> uint256:
    """
    Returns the share of losses that a user would take if withdrawing from this strategy
    e.g. if the strategy has unrealised losses for 10% of its current debt and the user wants to withdraw 1000 tokens, the losses that he will take are 100 token
    """
    strategy_current_debt: uint256 = self.strategies[strategy].current_debt
    assets_to_withdraw: uint256 = min(assets_needed, strategy_current_debt)
    vault_shares: uint256 = IStrategy(strategy).balanceOf(self)
    strategy_assets: uint256 = IStrategy(strategy).convertToAssets(vault_shares)
    
    # If no losses, return 0
    if strategy_assets >= strategy_current_debt or strategy_current_debt == 0:
        return 0

    # user will withdraw assets_to_withdraw divided by loss ratio (strategy_assets / strategy_current_debt - 1)
    # but will only receive assets_to_withdraw
    # NOTE: if there are unrealised losses, the user will take his share
    losses_user_share: uint256 = assets_to_withdraw - assets_to_withdraw * strategy_assets / strategy_current_debt
    return losses_user_share


@internal
def _redeem(sender: address, receiver: address, owner: address, shares_to_burn: uint256, strategies: DynArray[address, 10]) -> uint256:
    if sender != owner:
        self._spend_allowance(owner, sender, shares_to_burn)

    _strategies: DynArray[address, 10] = strategies

    queue_manager: address = self.queue_manager
    if queue_manager != empty(address):
        if len(_strategies) == 0 or IQueueManager(queue_manager).should_override(self):
            _strategies = IQueueManager(queue_manager).withdraw_queue(self)

    shares: uint256 = shares_to_burn
    shares_balance: uint256 = self.balance_of[owner]

    if shares == max_value(uint256):
        shares = shares_balance

    assert shares_balance >= shares, "insufficient shares to redeem"
    assert shares > 0, "no shares to redeem"

    requested_assets: uint256 = self._convert_to_assets(shares)

    # load to memory to save gas
    curr_total_idle: uint256 = self.total_idle
    
    # If there are not enough assets in the Vault contract, we try to free funds from strategies specified in the input
    if requested_assets > curr_total_idle:
        # load to memory to save gas
        curr_total_debt: uint256 = self.total_debt

        # Withdraw from strategies if insufficient total idle
        assets_needed: uint256 = requested_assets - curr_total_idle
        assets_to_withdraw: uint256 = 0

        # NOTE: to compare against real withdrawals from strategies
        previous_balance: uint256 = ASSET.balanceOf(self)
        for strategy in _strategies:
            assert self.strategies[strategy].activation != 0, "inactive strategy"
          
            # Starts with all the assets needed
            assets_to_withdraw = assets_needed

            # CHECK FOR UNREALISED LOSSES
            # If unrealised losses > 0, then the user will take the proportional share and realise it (required to avoid users withdrawing from lossy strategies) 
            # NOTE: assets_to_withdraw will be capped to strategy's current_debt within the function
            # NOTE: strategies need to manage the fact that realising part of the loss can mean the realisation of 100% of the loss !! (i.e. if for withdrawing 10% of the strategy it needs to unwind the whole position, generated losses might be bigger)
            unrealised_losses_share: uint256 = self._assess_share_of_unrealised_losses(strategy, assets_to_withdraw)
            if unrealised_losses_share > 0:
                # User now "needs" less assets to be unlocked (as he took some as losses)
                assets_to_withdraw -= unrealised_losses_share
                requested_assets -= unrealised_losses_share
                # NOTE: done here instead of waiting for regular update of these values because it's a rare case (so we can save minor amounts of gas)
                assets_needed -= unrealised_losses_share
                curr_total_debt -= unrealised_losses_share
            
            # After losses are taken, vault asks what is the max amount to withdraw
            assets_to_withdraw = min(assets_to_withdraw, min(self.strategies[strategy].current_debt, IStrategy(strategy).maxWithdraw(self)))

            # continue to next strategy if nothing to withdraw
            if assets_to_withdraw == 0:
                continue

            # WITHDRAW FROM STRATEGY
            IStrategy(strategy).withdraw(assets_to_withdraw, self, self)
            post_balance: uint256 = ASSET.balanceOf(self)
            
            # If we have not received what we expected, we consider the difference a loss
            loss: uint256 = 0
            if(previous_balance + assets_to_withdraw > post_balance):
                loss = previous_balance + assets_to_withdraw - post_balance

            # NOTE: we update the previous_balance variable here to save gas in next iteration
            previous_balance = post_balance
 
            # NOTE: strategy's debt decreases by the full amount but the total idle increases 
            # by the actual amount only (as the difference is considered lost)
            curr_total_idle += (assets_to_withdraw - loss)
            requested_assets -= loss
            curr_total_debt -= assets_to_withdraw
            # Vault will reduce debt because the unrealised loss has been taken by user
            self.strategies[strategy].current_debt -= (assets_to_withdraw + unrealised_losses_share)
            # NOTE: the user will receive less tokens (the rest were lost)
            # break if we have enough total idle to serve initial request 
            if requested_assets <= curr_total_idle:
                break

            assets_needed -= assets_to_withdraw

        # if we exhaust the queue and still have insufficient total idle, revert
        assert curr_total_idle >= requested_assets, "insufficient assets in vault"
        # commit memory to storage
        self.total_debt = curr_total_debt

    self._burn_shares(shares, owner)
    # commit memory to storage
    self.total_idle = curr_total_idle - requested_assets
    self.erc20_safe_transfer(ASSET.address, receiver, requested_assets)

    log Withdraw(sender, receiver, owner, requested_assets, shares)
    return requested_assets

## STRATEGY MANAGEMENT ##
@internal
def _add_strategy(new_strategy: address):
    assert new_strategy != empty(address), "strategy cannot be zero address"
    assert IStrategy(new_strategy).asset() == ASSET.address, "invalid asset"
    assert self.strategies[new_strategy].activation == 0, "strategy already active"

    self.strategies[new_strategy] = StrategyParams({
        activation: block.timestamp,
        last_report: block.timestamp,
        current_debt: 0,
        max_debt: 0
    })

    queue_manager: address = self.queue_manager
    if queue_manager != empty(address):        
        # tell the queue_manager we have a new strategy
        IQueueManager(queue_manager).new_strategy(new_strategy)

    log StrategyChanged(new_strategy, StrategyChangeType.ADDED)

@internal
def _revoke_strategy(strategy: address, force: bool=False):
    assert self.strategies[strategy].activation != 0, "strategy not active"
    loss: uint256 = 0
    
    if self.strategies[strategy].current_debt != 0:
        assert force, "strategy has debt"
        loss = self.strategies[strategy].current_debt
        self.total_debt -= loss
        log StrategyReported(strategy, 0, loss, 0, 0, 0, 0)

    # NOTE: strategy params are set to 0 (WARNING: it can be readded)
    self.strategies[strategy] = StrategyParams({
      activation: 0,
      last_report: 0,
      current_debt: 0,
      max_debt: 0
    })

    queue_manager: address = self.queue_manager
    if queue_manager != empty(address):
        # tell the queue_manager we removed a strategy
        IQueueManager(queue_manager).remove_strategy(strategy)

    log StrategyChanged(strategy, StrategyChangeType.REVOKED)

# DEBT MANAGEMENT #
@internal
def _update_debt(strategy: address, target_debt: uint256) -> uint256:
    """
    The vault will rebalance the debt vs target debt. Target debt must be smaller or equal to strategy's max_debt.
    This function will compare the current debt with the target debt and will take funds or deposit new 
    funds to the strategy. 

    The strategy can require a maximum amount of funds that it wants to receive to invest. 
    The strategy can also reject freeing funds if they are locked.

    The vault will not invest the funds into the underlying protocol, which is responsibility of the strategy. 
    """
    new_debt: uint256 = target_debt

    current_debt: uint256 = self.strategies[strategy].current_debt

    if self.shutdown:
        new_debt = 0

    assert new_debt != current_debt, "new debt equals current debt"

    if current_debt > new_debt:
        # reduce debt
        assets_to_withdraw: uint256 = current_debt - new_debt

        # ensure we always have minimum_total_idle when updating debt
        minimum_total_idle: uint256 = self.minimum_total_idle
        total_idle: uint256 = self.total_idle
        
        # Respect minimum total idle in vault
        if total_idle + assets_to_withdraw < minimum_total_idle:
            assets_to_withdraw = minimum_total_idle - total_idle
            if assets_to_withdraw > current_debt:
                assets_to_withdraw = current_debt

        withdrawable: uint256 = IStrategy(strategy).maxWithdraw(self)
        assert withdrawable != 0, "nothing to withdraw"

        # if insufficient withdrawable, withdraw what we can
        if withdrawable < assets_to_withdraw:
            assets_to_withdraw = withdrawable

        # If there are unrealised losses we don't let the vault reduce its debt until there is a new report
        unrealised_losses_share: uint256 = self._assess_share_of_unrealised_losses(strategy, assets_to_withdraw)
        assert unrealised_losses_share == 0, "strategy has unrealised losses"
        
        pre_balance: uint256 = ASSET.balanceOf(self)
        IStrategy(strategy).withdraw(assets_to_withdraw, self, self)
        post_balance: uint256 = ASSET.balanceOf(self)
        
        # making sure we are changing according to the real result no matter what. This will spend more gas but makes it more robust
        # also prevents issues from faulty strategy that either under or over delievers 'assets_to_withdraw'
        assets_to_withdraw = min(post_balance - pre_balance, current_debt)

        self.total_idle += assets_to_withdraw
        self.total_debt -= assets_to_withdraw
  
        new_debt = current_debt - assets_to_withdraw
    else:
        # Revert if target_debt cannot be achieved due to configured max_debt for given strategy
        assert new_debt <= self.strategies[strategy].max_debt, "target debt higher than max debt"
        # Vault is increasing debt with the strategy by sending more funds
        max_deposit: uint256 = IStrategy(strategy).maxDeposit(self)

        assets_to_deposit: uint256 = new_debt - current_debt
        if assets_to_deposit > max_deposit:
            assets_to_deposit = max_deposit
        # take into consideration minimum_total_idle
        # HACK: to save gas
        minimum_total_idle: uint256 = self.minimum_total_idle
        total_idle: uint256 = self.total_idle

        assert total_idle > minimum_total_idle, "no funds to deposit"
        available_idle: uint256 = total_idle - minimum_total_idle

        # if insufficient funds to deposit, transfer only what is free
        if assets_to_deposit > available_idle:
            assets_to_deposit = available_idle

        if assets_to_deposit > 0:
            self.erc20_safe_approve(ASSET.address, strategy, assets_to_deposit)
            pre_balance: uint256 = ASSET.balanceOf(self)
            IStrategy(strategy).deposit(assets_to_deposit, self)
            post_balance: uint256 = ASSET.balanceOf(self)
            self.erc20_safe_approve(ASSET.address, strategy, 0)

            # making sure we are changing according to the real result no matter what. This will spend more gas but makes it more robust
            assets_to_deposit = pre_balance - post_balance

            self.total_idle -= assets_to_deposit
            self.total_debt += assets_to_deposit

        new_debt = current_debt + assets_to_deposit

    # commit memory to storage
    self.strategies[strategy].current_debt = new_debt

    log DebtUpdated(strategy, current_debt, new_debt)
    return new_debt

@internal
def _assess_protocol_fees() -> (uint256, address):
    protocol_fees: uint256 = 0
    protocol_fee_recipient: address = empty(address)
    seconds_since_last_report: uint256 = block.timestamp - self.last_report
    # to avoid wasting gas for minimal fees vault will only assess once every PROTOCOL_FEE_ASSESSMENT_PERIOD seconds
    if(seconds_since_last_report >= PROTOCOL_FEE_ASSESSMENT_PERIOD):
        protocol_fee_bps: uint16 = 0
        protocol_fee_last_change: uint32 = 0

        protocol_fee_bps, protocol_fee_last_change, protocol_fee_recipient = IFactory(FACTORY).protocol_fee_config()

        if(protocol_fee_bps > 0):
            # NOTE: charge fees since last report OR last fee change (this will mean less fees are charged after a change in protocol_fees, but fees should not change frequently)
            seconds_since_last_report = min(seconds_since_last_report, block.timestamp - convert(protocol_fee_last_change, uint256))
            protocol_fees = convert(protocol_fee_bps, uint256) * self._total_assets() * seconds_since_last_report / 24 / 365 / 3600 / MAX_BPS
            self.last_report = block.timestamp
    return (protocol_fees, protocol_fee_recipient)


## ACCOUNTING MANAGEMENT ##
@internal
def _process_report(strategy: address) -> (uint256, uint256):
    """
    Processing a report means comparing the debt that the strategy has taken with the current amount of funds it is reporting
    If the strategy owes less than it currently has, it means it has had a profit
    Else (assets < debt) it has had a loss

    Different strategies might choose different reporting strategies: pessimistic, only realised P&L, ...
    The best way to report depends on the strategy

    The profit will be distributed following a smooth curve over the next profit_max_unlock_time seconds. 
    Losses will be taken immediately, first from the profit buffer (avoiding an impact in pps), then will reduce pps
    """
    assert self.strategies[strategy].activation != 0, "inactive strategy"

    # Vault needs to assess 
    # Using strategy shares because some may be a ERC4626 vault
    strategy_shares: uint256 = IStrategy(strategy).balanceOf(self)
    total_assets: uint256 = IStrategy(strategy).convertToAssets(strategy_shares)
    current_debt: uint256 = self.strategies[strategy].current_debt
    
    # Burn shares that have been unlocked since the last update
    self._burn_unlocked_shares()

    gain: uint256 = 0
    loss: uint256 = 0

    if total_assets > current_debt:
        gain = total_assets - current_debt
    else:
        loss = current_debt - total_assets

    total_fees: uint256 = 0
    total_refunds: uint256 = 0

    accountant: address = self.accountant
    # if accountant is not set, fees and refunds remain unchanged
    if accountant != empty(address):
        total_fees, total_refunds = IAccountant(accountant).report(strategy, gain, loss)

    # Protocol fee assessment
    protocol_fees: uint256 = 0
    protocol_fee_recipient: address = empty(address)
    protocol_fees, protocol_fee_recipient = self._assess_protocol_fees()
    total_fees += protocol_fees

    # We calculate the amount of shares that could be insta unlocked to avoid pps changes
    # NOTE: this needs to be done before any pps changes
    shares_to_burn: uint256 = 0
    accountant_fees_shares: uint256 = 0
    protocol_fees_shares: uint256 = 0
    if loss + total_fees > 0:
        shares_to_burn += self._convert_to_shares(loss + total_fees)
        # Vault calculates the amount of shares to mint as fees before changing totalAssets / totalSupply
        if total_fees > 0:
            accountant_fees_shares = self._convert_to_shares(total_fees - protocol_fees)
            if protocol_fees > 0:
                protocol_fees_shares = self._convert_to_shares(protocol_fees)

    newly_locked_shares: uint256 = 0
    if total_refunds > 0:
        # if refunds are non-zero, transfer shares worth of assets
        total_refunds_shares: uint256 = min(self._convert_to_shares(total_refunds), self.balance_of[accountant])
        # Shares received as a refund are locked to avoid sudden pps change (like profits)
        self._transfer(accountant, self, total_refunds_shares)
        newly_locked_shares += total_refunds_shares

    if gain > 0:
        # NOTE: this will increase total_assets
        self.strategies[strategy].current_debt += gain
        self.total_debt += gain

        # NOTE: vault will issue shares worth the profit to avoid instant pps change
        newly_locked_shares += self._issue_shares_for_amount(gain, self)

    # Strategy is reporting a loss
    if loss > 0:
        self.strategies[strategy].current_debt -= loss
        self.total_debt -= loss

    # NOTE: should be precise (no new unlocked shares due to above's burn of shares)
    # newly_locked_shares have already been minted / transfered to the vault, so they need to be substracted
    # no risk of underflow because they have just been minted
    previously_locked_shares: uint256 = self.balance_of[self] - newly_locked_shares

    # Now that pps has updated, we can burn the shares we intended to burn as a result of losses/fees.
    # NOTE: If a value reduction (losses / fees) has occured, prioritize burning locked profit to avoid
    # negative impact on price per share. Price per share is reduced only if losses exceed locked value.
    if shares_to_burn > 0:
        shares_to_burn = min(shares_to_burn, previously_locked_shares + newly_locked_shares)
        self._burn_shares(shares_to_burn, self)
        # we burn first the newly locked shares, then the previously locked shares
        shares_not_to_lock: uint256 = min(shares_to_burn, newly_locked_shares)
        newly_locked_shares -= shares_not_to_lock
        previously_locked_shares -= (shares_to_burn - shares_not_to_lock)

    # issue shares that were calculated above
    if accountant_fees_shares > 0:
        self._issue_shares(accountant_fees_shares, accountant)

    if protocol_fees_shares > 0:
        self._issue_shares(protocol_fees_shares, protocol_fee_recipient)

    # Calculate how long until the full amount of shares is unlocked
    remaining_time: uint256 = 0
    _full_profit_unlock_date: uint256 = self.full_profit_unlock_date
    if _full_profit_unlock_date > block.timestamp: 
        remaining_time = _full_profit_unlock_date - block.timestamp

    # Update unlocking rate and time to fully unlocked
    total_locked_shares: uint256 = previously_locked_shares + newly_locked_shares
    _profit_max_unlock_time: uint256 = self.profit_max_unlock_time
    if total_locked_shares > 0 and _profit_max_unlock_time > 0:
        # new_profit_locking_period is a weighted average between the remaining time of the previously locked shares and the profit_max_unlock_time
        new_profit_locking_period: uint256 = (previously_locked_shares * remaining_time + newly_locked_shares * _profit_max_unlock_time) / total_locked_shares
        self.profit_unlocking_rate = total_locked_shares * MAX_BPS_EXTENDED / new_profit_locking_period
        self.full_profit_unlock_date = block.timestamp + new_profit_locking_period
        self.last_profit_update = block.timestamp
    else:
        # NOTE: only setting this to 0 will turn in the desired effect, no need to update last_profit_update or full_profit_unlock_date
        self.profit_unlocking_rate = 0

    self.strategies[strategy].last_report = block.timestamp

    log StrategyReported(
        strategy,
        gain,
        loss,
        self.strategies[strategy].current_debt,
        self._convert_to_assets(protocol_fees_shares),
        self._convert_to_assets(protocol_fees_shares + accountant_fees_shares),
        total_refunds
    )
    return (gain, loss)


# SETTERS #
@external
def set_accountant(new_accountant: address):
    self._enforce_role(msg.sender, Roles.ACCOUNTANT_MANAGER)
    self.accountant = new_accountant
    log UpdateAccountant(new_accountant)

@external
def set_queue_manager(new_queue_manager: address):
    self._enforce_role(msg.sender, Roles.QUEUE_MANAGER)
    self.queue_manager = new_queue_manager
    log UpdateQueueManager(new_queue_manager)

@external
def set_deposit_limit(deposit_limit: uint256):
    self._enforce_role(msg.sender, Roles.DEPOSIT_LIMIT_MANAGER)
    self.deposit_limit = deposit_limit
    log UpdateDepositLimit(deposit_limit)

@external
def set_minimum_total_idle(minimum_total_idle: uint256):
    self._enforce_role(msg.sender, Roles.MINIMUM_IDLE_MANAGER)
    self.minimum_total_idle = minimum_total_idle
    log UpdateMinimumTotalIdle(minimum_total_idle)

@external
def set_profit_max_unlock_time(new_profit_max_unlock_time: uint256):
    # no need to update locking period as the current period will use the old rate
    # and on the next report it will be reset with the new unlocking time
    self._enforce_role(msg.sender, Roles.PROFIT_UNLOCK_MANAGER)
    self.profit_max_unlock_time = new_profit_max_unlock_time
    log UpdateProfitMaxUnlockTime(new_profit_max_unlock_time)

# ROLE MANAGEMENT #
@internal
def _enforce_role(account: address, role: Roles):
    assert role in self.roles[account] or self.open_roles[role], "not allowed"

@external
def set_role(account: address, role: Roles):
    assert msg.sender == self.role_manager
    self.roles[account] = role

@external
def set_open_role(role: Roles):
    assert msg.sender == self.role_manager
    self.open_roles[role] = True

@external
def close_open_role(role: Roles):
    assert msg.sender == self.role_manager
    self.open_roles[role] = False
    
@external
def transfer_role_manager(role_manager: address):
    assert msg.sender == self.role_manager
    self.future_role_manager = role_manager

@external
def accept_role_manager():
    assert msg.sender == self.future_role_manager
    self.role_manager = msg.sender
    self.future_role_manager = empty(address)

# VAULT STATUS VIEWS
@view
@external
def unlocked_shares() -> uint256:
  return self._unlocked_shares()


@view
@external
def price_per_share() -> uint256:
    """
    This value offers limited precision.
    Integrations the require exact precision should use convertToAssets or
    convertToShares instead.
    """
    return self._convert_to_assets(10 ** DECIMALS)

@view
@external
def available_deposit_limit() -> uint256:
    if self.deposit_limit > self._total_assets():
        return self.deposit_limit - self._total_assets()
    return 0

## REPORTING MANAGEMENT ##
@external
def process_report(strategy: address) -> (uint256, uint256):
    self._enforce_role(msg.sender, Roles.REPORTING_MANAGER)
    return self._process_report(strategy)

@external
def sweep(token: address) -> (uint256):
    self._enforce_role(msg.sender, Roles.SWEEPER)
    assert token != self, "can't sweep self"
    assert self.strategies[token].activation == 0, "can't sweep strategy"
    amount: uint256 = 0
    if token == ASSET.address:
        amount = ASSET.balanceOf(self) - self.total_idle
    else:
        amount = ERC20(token).balanceOf(self)
    assert amount != 0, "no dust"
    self.erc20_safe_transfer(token, msg.sender, amount)
    log Sweep(token, amount)
    return amount

## STRATEGY MANAGEMENT ##
@external
def add_strategy(new_strategy: address):
    self._enforce_role(msg.sender, Roles.ADD_STRATEGY_MANAGER)
    self._add_strategy(new_strategy)

@external
def revoke_strategy(strategy: address):
    self._enforce_role(msg.sender, Roles.REVOKE_STRATEGY_MANAGER)
    self._revoke_strategy(strategy)

@external
def force_revoke_strategy(strategy: address):
    """
    The vault will remove the inputed strategy and write off any debt left in it as loss. 
    This function is a dangerous function as it can force a strategy to take a loss. 
    All possible assets should be removed from the strategy first via update_debt
    Note that if a strategy is removed erroneously it can be re-added and the loss will be credited as profit. Fees will apply
    """
    self._enforce_role(msg.sender, Roles.FORCE_REVOKE_MANAGER)
    self._revoke_strategy(strategy, True)

## DEBT MANAGEMENT ##
@external
def update_max_debt_for_strategy(strategy: address, new_max_debt: uint256):
    self._enforce_role(msg.sender, Roles.MAX_DEBT_MANAGER)
    assert self.strategies[strategy].activation != 0, "inactive strategy"
    self.strategies[strategy].max_debt = new_max_debt

    log UpdatedMaxDebtForStrategy(msg.sender, strategy, new_max_debt)

@external
@nonreentrant("lock")
def update_debt(strategy: address, target_debt: uint256) -> uint256:
    self._enforce_role(msg.sender, Roles.DEBT_MANAGER)
    return self._update_debt(strategy, target_debt)

## EMERGENCY MANAGEMENT ##
@external
def shutdown_vault():
    self._enforce_role(msg.sender, Roles.EMERGENCY_MANAGER)
    assert self.shutdown == False
    self.shutdown = True
    self.roles[msg.sender] = self.roles[msg.sender] | Roles.DEBT_MANAGER
    log Shutdown()


## SHARE MANAGEMENT ##
## ERC20 + ERC4626 ##
@external
@nonreentrant("lock")
def deposit(assets: uint256, receiver: address) -> uint256:
    return self._deposit(msg.sender, receiver, assets)

@external
@nonreentrant("lock")
def mint(shares: uint256, receiver: address) -> uint256:
    assets: uint256 = self._convert_to_assets(shares)
    self._deposit(msg.sender, receiver, assets)
    return assets

@external
@nonreentrant("lock")
def withdraw(assets: uint256, receiver: address, owner: address, strategies: DynArray[address, 10] = []) -> uint256:
    shares: uint256 = self._convert_to_shares(assets)
    self._redeem(msg.sender, receiver, owner, shares, strategies)
    return shares

@external
@nonreentrant("lock")
def redeem(shares: uint256, receiver: address, owner: address, strategies: DynArray[address, 10] = []) -> uint256:
    assets: uint256 = self._redeem(msg.sender, receiver, owner, shares, strategies)
    return assets

@external
def approve(spender: address, amount: uint256) -> bool:
    return self._approve(msg.sender, spender, amount)

@external
def transfer(receiver: address, amount: uint256) -> bool:
    assert receiver not in [self, empty(address)]
    self._transfer(msg.sender, receiver, amount)
    return True

@external
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
    assert receiver not in [self, empty(address)]
    return self._transfer_from(sender, receiver, amount)

## ERC20+4626 compatibility
@external
def increaseAllowance(spender: address, amount: uint256) -> bool:
    return self._increase_allowance(msg.sender, spender, amount)

@external
def decreaseAllowance(spender: address, amount: uint256) -> bool:
    return self._decrease_allowance(msg.sender, spender, amount)

@external
def permit(owner: address, spender: address, amount: uint256, deadline: uint256, v: uint8, r: bytes32, s: bytes32) -> bool:
    return self._permit(owner, spender, amount, deadline, v, r, s)

@view
@external
def balanceOf(addr: address) -> uint256:
    if(addr == self):
      return self.balance_of[addr] - self._unlocked_shares()
    return self.balance_of[addr]

@view
@external
def totalSupply() -> uint256:
    return self._total_supply()

@view
@external
def asset() -> address:
    return ASSET.address

@view
@external
def decimals() -> uint256:
    return DECIMALS

@view
@external
def totalAssets() -> uint256:
    return self._total_assets()

@view
@external
def convertToShares(assets: uint256) -> uint256:
    return self._convert_to_shares(assets)

@view
@external
def previewDeposit(assets: uint256) -> uint256:
    return self._convert_to_shares(assets)

@view
@external
def previewMint(shares: uint256) -> uint256:
    return self._convert_to_assets(shares)

@view
@external
def convertToAssets(shares: uint256) -> uint256:
    return self._convert_to_assets(shares)

@view
@external
def maxDeposit(receiver: address) -> uint256:
    return self._max_deposit(receiver)

@view
@external
def maxMint(receiver: address) -> uint256:
    max_deposit: uint256 = self._max_deposit(receiver)
    return self._convert_to_shares(max_deposit)

@view
@external
def maxWithdraw(owner: address) -> uint256:
    # NOTE: as the withdraw function that complies with ERC4626 won't withdraw from strategies, this just uses liquidity available in the vault contract
    max_withdraw: uint256 = self._max_redeem(owner) # should be moved to a max_withdraw internal function
    return self._convert_to_assets(max_withdraw)

@view
@external
def maxRedeem(owner: address) -> uint256:
    # NOTE: as the withdraw function that complies with ERC4626 won't withdraw from strategies, this just uses liquidity available in the vault contract
    return self._max_redeem(owner)

@view
@external
def previewWithdraw(assets: uint256) -> uint256:
    return self._convert_to_shares(assets)

@view
@external
def previewRedeem(shares: uint256) -> uint256:
   return self._convert_to_assets(shares)

@view
@external
def api_version() -> String[28]:
    return API_VERSION

@view
@external
def assess_share_of_unrealised_losses(strategy: address, assets_needed: uint256) -> uint256:
  return self._assess_share_of_unrealised_losses(strategy, assets_needed)

# eip-1344
@view
@internal
def domain_separator() -> bytes32:
    return keccak256(
        concat(
            DOMAIN_TYPE_HASH,
            keccak256(convert("Yearn Vault", Bytes[11])),
            keccak256(convert(API_VERSION, Bytes[28])),
            convert(chain.id, bytes32),
            convert(self, bytes32)
        )
    )

@view
@external
def DOMAIN_SEPARATOR() -> bytes32:
    return self.domain_separator()
