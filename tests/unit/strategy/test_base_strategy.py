from ape import chain


# placeholder tests for test mocks
def test_base_strategy__deposit(
    gov, asset, vault, generic_strategy, mint_and_deposit_into_strategy
):
    strategy = generic_strategy
    amount = 10**18

    mint_and_deposit_into_strategy(strategy, vault, amount)

    assert asset.balanceOf(strategy) == amount
    assert strategy.maxWithdraw(vault) == amount


