**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [arbitrary-send-eth](#arbitrary-send-eth) (2 results) (High)
 - [unchecked-transfer](#unchecked-transfer) (10 results) (High)
 - [divide-before-multiply](#divide-before-multiply) (2 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (23 results) (Medium)
 - [locked-ether](#locked-ether) (1 results) (Medium)
 - [pyth-unchecked-confidence](#pyth-unchecked-confidence) (2 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (4 results) (Medium)
 - [uninitialized-local](#uninitialized-local) (4 results) (Medium)
 - [unused-return](#unused-return) (44 results) (Medium)
 - [missing-zero-check](#missing-zero-check) (1 results) (Low)
 - [reentrancy-benign](#reentrancy-benign) (22 results) (Low)
 - [reentrancy-events](#reentrancy-events) (4 results) (Low)
 - [timestamp](#timestamp) (15 results) (Low)
 - [assembly](#assembly) (1 results) (Informational)
 - [cyclomatic-complexity](#cyclomatic-complexity) (1 results) (Informational)
 - [low-level-calls](#low-level-calls) (4 results) (Informational)
 - [missing-inheritance](#missing-inheritance) (2 results) (Informational)
 - [naming-convention](#naming-convention) (14 results) (Informational)
 - [immutable-states](#immutable-states) (6 results) (Optimization)
## arbitrary-send-eth
Impact: High
Confidence: Medium
 - [ ] ID-0
[OracleAggregator.updatePythFeeds(bytes[])](src/OracleAggregator.sol#L330-L343) sends eth to arbitrary user
	Dangerous calls:
	- [pyth.updatePriceFeeds{value: fee}(updateData)](src/OracleAggregator.sol#L337)

src/OracleAggregator.sol#L330-L343


 - [ ] ID-1
[KeeperRegistry.sweepSlashedFunds(address)](src/KeeperRegistry.sol#L379-L394) sends eth to arbitrary user
	Dangerous calls:
	- [(ok,None) = to.call{value: amount}()](src/KeeperRegistry.sol#L390)

src/KeeperRegistry.sol#L379-L394


## unchecked-transfer
Impact: High
Confidence: Medium
 - [ ] ID-2
[RAYPVault.mint(uint256,address)](src/RAYPVault.sol#L259-L281) ignores return value by [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L274)

src/RAYPVault.sol#L259-L281


 - [ ] ID-3
[RAYPVault.redeem(uint256,address,address)](src/RAYPVault.sol#L326-L356) ignores return value by [asset.transfer(treasury,fee)](src/RAYPVault.sol#L351)

src/RAYPVault.sol#L326-L356


 - [ ] ID-4
[RAYPVault.deposit(uint256,address)](src/RAYPVault.sol#L229-L254) ignores return value by [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L246)

src/RAYPVault.sol#L229-L254


 - [ ] ID-5
[BaseStrategy.withdraw(uint256,address,uint256)](src/BaseStrategy.sol#L123-L147) ignores return value by [IERC20(asset).transfer(recipient,assetsOut)](src/BaseStrategy.sol#L140)

src/BaseStrategy.sol#L123-L147


 - [ ] ID-6
[RAYPVault.redeem(uint256,address,address)](src/RAYPVault.sol#L326-L356) ignores return value by [asset.transfer(receiver,actual - fee)](src/RAYPVault.sol#L352)

src/RAYPVault.sol#L326-L356


 - [ ] ID-7
[RAYPVault.withdraw(uint256,address,address)](src/RAYPVault.sol#L289-L321) ignores return value by [asset.transfer(treasury,fee)](src/RAYPVault.sol#L316)

src/RAYPVault.sol#L289-L321


 - [ ] ID-8
[RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543) ignores return value by [asset.transfer(address(newStrat),assetsToDeploy)](src/RAYPVault.sol#L529)

src/RAYPVault.sol#L459-L543


 - [ ] ID-9
[BaseStrategy.withdrawAll(address,uint256)](src/BaseStrategy.sol#L157-L185) ignores return value by [IERC20(asset).transfer(recipient,bal)](src/BaseStrategy.sol#L177)

src/BaseStrategy.sol#L157-L185


 - [ ] ID-10
[RAYPVault._deployToStrategy(uint256)](src/RAYPVault.sol#L739-L745) ignores return value by [asset.transfer(address(strat),assets)](src/RAYPVault.sol#L743)

src/RAYPVault.sol#L739-L745


 - [ ] ID-11
[RAYPVault.withdraw(uint256,address,address)](src/RAYPVault.sol#L289-L321) ignores return value by [asset.transfer(receiver,actual - fee)](src/RAYPVault.sol#L317)

src/RAYPVault.sol#L289-L321


## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-12
[OracleAggregator._readPyth()](src/OracleAggregator.sol#L445-L473) performs a multiplication on the result of a division:
	- [dailySigma = (uint256(pp.conf) * 1e18) / uint256(uint64(pp.price))](src/OracleAggregator.sol#L468)
	- [vol18 = (dailySigma * 191_000_000) / 1e7](src/OracleAggregator.sol#L469)

src/OracleAggregator.sol#L445-L473


 - [ ] ID-13
[RAYPVault.harvestFees()](src/RAYPVault.sol#L578-L607) performs a multiplication on the result of a division:
	- [totalGain = (gainPerShare * totalSupply) / 1e18](src/RAYPVault.sol#L589)
	- [feeAssets = (totalGain * performanceFeeBps) / 10_000](src/RAYPVault.sol#L590)

src/RAYPVault.sol#L578-L607


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-14
[BullStrategy._liquidate(uint256)](src/BullStrategy.sol#L137-L158) uses a dangerous strict equality:
	- [debtBal == 0](src/BullStrategy.sol#L141)

src/BullStrategy.sol#L137-L158


 - [ ] ID-15
[BullStrategy._liquidateAll()](src/BullStrategy.sol#L160-L179) uses a dangerous strict equality:
	- [supplyBal == 0](src/BullStrategy.sol#L165)

src/BullStrategy.sol#L160-L179


 - [ ] ID-16
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) uses a dangerous strict equality:
	- [totalDeposited > 0 && aWETH.balanceOf(address(this)) == 0](src/BullStrategy.sol#L320)

src/BullStrategy.sol#L303-L330


 - [ ] ID-17
[RAYPVault.convertToShares(uint256)](src/RAYPVault.sol#L373-L377) uses a dangerous strict equality:
	- [supply == 0](src/RAYPVault.sol#L375)

src/RAYPVault.sol#L373-L377


 - [ ] ID-18
[RAYPVault.withdraw(uint256,address,address)](src/RAYPVault.sol#L289-L321) uses a dangerous strict equality:
	- [shares == 0](src/RAYPVault.sol#L303)

src/RAYPVault.sol#L289-L321


 - [ ] ID-19
[RAYPVault.harvestFees()](src/RAYPVault.sol#L578-L607) uses a dangerous strict equality:
	- [feeAssets == 0](src/RAYPVault.sol#L592)

src/RAYPVault.sol#L578-L607


 - [ ] ID-20
[BearStrategy._usdcToWeth(uint256)](src/BearStrategy.sol#L233-L238) uses a dangerous strict equality:
	- [usdcAmount == 0](src/BearStrategy.sol#L234)

src/BearStrategy.sol#L233-L238


 - [ ] ID-21
[BullStrategy.totalAssets()](src/BullStrategy.sol#L103-L112) uses a dangerous strict equality:
	- [debtUsdc == 0](src/BullStrategy.sol#L108)

src/BullStrategy.sol#L103-L112


 - [ ] ID-22
[RAYPVault._computeSharePriceFromFreeAssets(uint256)](src/RAYPVault.sol#L747-L751) uses a dangerous strict equality:
	- [supply == 0](src/RAYPVault.sol#L749)

src/RAYPVault.sol#L747-L751


 - [ ] ID-23
[BearStrategy.totalAssets()](src/BearStrategy.sol#L91-L95) uses a dangerous strict equality:
	- [usdcBalance == 0](src/BearStrategy.sol#L93)

src/BearStrategy.sol#L91-L95


 - [ ] ID-24
[BullStrategy._liquidate(uint256)](src/BullStrategy.sol#L137-L158) uses a dangerous strict equality:
	- [usdcToRepay == 0](src/BullStrategy.sol#L149)

src/BullStrategy.sol#L137-L158


 - [ ] ID-25
[BullStrategy.totalAssets()](src/BullStrategy.sol#L103-L112) uses a dangerous strict equality:
	- [supplyWeth == 0](src/BullStrategy.sol#L105)

src/BullStrategy.sol#L103-L112


 - [ ] ID-26
[BullStrategy._liquidateAll()](src/BullStrategy.sol#L160-L179) uses a dangerous strict equality:
	- [debtBal == 0](src/BullStrategy.sol#L163)

src/BullStrategy.sol#L160-L179


 - [ ] ID-27
[RAYPVault.redeem(uint256,address,address)](src/RAYPVault.sol#L326-L356) uses a dangerous strict equality:
	- [assets == 0](src/RAYPVault.sol#L340)

src/RAYPVault.sol#L326-L356


 - [ ] ID-28
[AaveMoneyMarketStrategy._checkProtocolHealth()](src/AaveMoneyMarketStrategy.sol#L121-L144) uses a dangerous strict equality:
	- [totalDeposited > 0 && aBalance == 0](src/AaveMoneyMarketStrategy.sol#L132)

src/AaveMoneyMarketStrategy.sol#L121-L144


 - [ ] ID-29
[RAYPVault.mint(uint256,address)](src/RAYPVault.sol#L259-L281) uses a dangerous strict equality:
	- [assets == 0](src/RAYPVault.sol#L269)

src/RAYPVault.sol#L259-L281


 - [ ] ID-30
[BullStrategy._usdcToWeth(uint256)](src/BullStrategy.sol#L342-L347) uses a dangerous strict equality:
	- [usdcAmount == 0](src/BullStrategy.sol#L343)

src/BullStrategy.sol#L342-L347


 - [ ] ID-31
[BearStrategy._liquidateAll()](src/BearStrategy.sol#L146-L163) uses a dangerous strict equality:
	- [aBalance == 0](src/BearStrategy.sol#L148)

src/BearStrategy.sol#L146-L163


 - [ ] ID-32
[KeeperRegistry.executeRebalance(uint256)](src/KeeperRegistry.sol#L262-L307) uses a dangerous strict equality:
	- [block.number == lastRebalanceBlock](src/KeeperRegistry.sol#L279)

src/KeeperRegistry.sol#L262-L307


 - [ ] ID-33
[AaveMoneyMarketStrategy._liquidateAll()](src/AaveMoneyMarketStrategy.sol#L85-L90) uses a dangerous strict equality:
	- [bal == 0](src/AaveMoneyMarketStrategy.sol#L87)

src/AaveMoneyMarketStrategy.sol#L85-L90


 - [ ] ID-34
[RAYPVault.deposit(uint256,address)](src/RAYPVault.sol#L229-L254) uses a dangerous strict equality:
	- [shares == 0](src/RAYPVault.sol#L243)

src/RAYPVault.sol#L229-L254


 - [ ] ID-35
[BearStrategy._checkProtocolHealth()](src/BearStrategy.sol#L194-L221) uses a dangerous strict equality:
	- [totalDepositedUSDC > 0 && aBalance == 0](src/BearStrategy.sol#L204)

src/BearStrategy.sol#L194-L221


 - [ ] ID-36
[RAYPVault.convertToAssets(uint256)](src/RAYPVault.sol#L379-L383) uses a dangerous strict equality:
	- [supply == 0](src/RAYPVault.sol#L381)

src/RAYPVault.sol#L379-L383


## locked-ether
Impact: Medium
Confidence: High
 - [ ] ID-37
Contract locking ether found:
	Contract [RAYPVault](src/RAYPVault.sol#L92-L789) has payable functions:
	 - [RAYPVault.receive()](src/RAYPVault.sol#L788)
	But does not have a function to withdraw the ether

src/RAYPVault.sol#L92-L789


## pyth-unchecked-confidence
Impact: Medium
Confidence: High
 - [ ] ID-38
Pyth price conf field is not checked in [OracleAggregator._readPyth()](src/OracleAggregator.sol#L445-L473)
	- [pv = pyth.getPriceNoOlderThan(pythVolId,PYTH_MAX_AGE)](src/OracleAggregator.sol#L462-L472)

src/OracleAggregator.sol#L445-L473


 - [ ] ID-39
Pyth price conf field is not checked in [OracleAggregator._readPyth()](src/OracleAggregator.sol#L445-L473)
	- [pp = pyth.getPriceNoOlderThan(pythPriceId,PYTH_MAX_AGE)](src/OracleAggregator.sol#L449)

src/OracleAggregator.sol#L445-L473


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-40
Reentrancy in [RAYPVault.mint(uint256,address)](src/RAYPVault.sol#L259-L281):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L274)
	State variables written after the call(s):
	- [_mint(receiver,shares)](src/RAYPVault.sol#L275)
		- [totalSupply += amount](src/RAYPVault.sol#L768)
	[RAYPVault.totalSupply](src/RAYPVault.sol#L109) can be used in cross function reentrancies:
	- [RAYPVault.convertToAssets(uint256)](src/RAYPVault.sol#L379-L383)
	- [RAYPVault.convertToShares(uint256)](src/RAYPVault.sol#L373-L377)
	- [RAYPVault.totalSupply](src/RAYPVault.sol#L109)

src/RAYPVault.sol#L259-L281


 - [ ] ID-41
Reentrancy in [RAYPVault.deposit(uint256,address)](src/RAYPVault.sol#L229-L254):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L246)
	State variables written after the call(s):
	- [_mint(receiver,shares)](src/RAYPVault.sol#L247)
		- [totalSupply += amount](src/RAYPVault.sol#L768)
	[RAYPVault.totalSupply](src/RAYPVault.sol#L109) can be used in cross function reentrancies:
	- [RAYPVault.convertToAssets(uint256)](src/RAYPVault.sol#L379-L383)
	- [RAYPVault.convertToShares(uint256)](src/RAYPVault.sol#L373-L377)
	- [RAYPVault.totalSupply](src/RAYPVault.sol#L109)

src/RAYPVault.sol#L229-L254


 - [ ] ID-42
Reentrancy in [RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543):
	External calls:
	- [(healthy,reason) = oldStrat.healthCheck()](src/RAYPVault.sol#L478)
	State variables written after the call(s):
	- [activeRegime = toRegime](src/RAYPVault.sol#L486)
	[RAYPVault.activeRegime](src/RAYPVault.sol#L117) can be used in cross function reentrancies:
	- [RAYPVault.activeRegime](src/RAYPVault.sol#L117)
	- [RAYPVault.constructor(address,address,address,address,address,uint8)](src/RAYPVault.sol#L197-L219)
	- [RAYPVault.totalAssets()](src/RAYPVault.sol#L365-L371)

src/RAYPVault.sol#L459-L543


 - [ ] ID-43
Reentrancy in [KeeperRegistry.executeRebalance(uint256)](src/KeeperRegistry.sol#L262-L307):
	External calls:
	- [vault.executeRebalance(minSharesOut)](src/KeeperRegistry.sol#L291-L306)
	State variables written after the call(s):
	- [keepers[msg.sender].totalRebalances -= 1](src/KeeperRegistry.sol#L301)
	[KeeperRegistry.keepers](src/KeeperRegistry.sol#L108) can be used in cross function reentrancies:
	- [KeeperRegistry.isAuthorizedKeeper(address)](src/KeeperRegistry.sol#L439-L442)
	- [KeeperRegistry.keepers](src/KeeperRegistry.sol#L108)
	- [lastRebalanceAt = 0](src/KeeperRegistry.sol#L299)
	[KeeperRegistry.lastRebalanceAt](src/KeeperRegistry.sol#L115) can be used in cross function reentrancies:
	- [KeeperRegistry.cooldownRemaining()](src/KeeperRegistry.sol#L445-L449)
	- [KeeperRegistry.lastRebalanceAt](src/KeeperRegistry.sol#L115)
	- [lastRebalanceBlock = 0](src/KeeperRegistry.sol#L300)
	[KeeperRegistry.lastRebalanceBlock](src/KeeperRegistry.sol#L118) can be used in cross function reentrancies:
	- [KeeperRegistry.lastRebalanceBlock](src/KeeperRegistry.sol#L118)

src/KeeperRegistry.sol#L262-L307


## uninitialized-local
Impact: Medium
Confidence: Medium
 - [ ] ID-44
[OracleAggregator._computeTwap().count](src/OracleAggregator.sol#L530) is a local variable never initialized

src/OracleAggregator.sol#L530


 - [ ] ID-45
[OracleAggregator._computeTwap().sum](src/OracleAggregator.sol#L529) is a local variable never initialized

src/OracleAggregator.sol#L529


 - [ ] ID-46
[RAYPVault._computeTwap().sum](src/RAYPVault.sol#L642) is a local variable never initialized

src/RAYPVault.sol#L642


 - [ ] ID-47
[BaseStrategy.healthCheck().assets](src/BaseStrategy.sol#L239) is a local variable never initialized

src/BaseStrategy.sol#L239


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-48
[RAYPVault._deployToStrategy(uint256)](src/RAYPVault.sol#L739-L745) ignores return value by [asset.approve(address(strat),assets)](src/RAYPVault.sol#L742)

src/RAYPVault.sol#L739-L745


 - [ ] ID-49
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) ignores return value by [(configUsdc,None,None,None,None,None,None,None,None,None,None,None,None,None,None) = aavePool.getReserveData(address(usdc))](src/BullStrategy.sol#L312)

src/BullStrategy.sol#L303-L330


 - [ ] ID-50
[BearStrategy._checkProtocolHealth()](src/BearStrategy.sol#L194-L221) ignores return value by [(configuration,None,None,None,None,None,None,None,None,None,None,None,None,None,None) = aavePool.getReserveData(address(usdc))](src/BearStrategy.sol#L200)

src/BearStrategy.sol#L194-L221


 - [ ] ID-51
[AaveMoneyMarketStrategy._harvestRewards()](src/AaveMoneyMarketStrategy.sol#L92-L119) ignores return value by [(None,amounts) = aaveRewards.claimAllRewards(aTokens,address(this))](src/AaveMoneyMarketStrategy.sol#L96)

src/AaveMoneyMarketStrategy.sol#L92-L119


 - [ ] ID-52
[RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543) ignores return value by [asset.approve(address(newStrat),assetsToDeploy)](src/RAYPVault.sol#L528)

src/RAYPVault.sol#L459-L543


 - [ ] ID-53
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [(None,None,None,None,None,None,None,None,_aWETH,None,None,None,None,None,None) = IAavePool(_aavePool).getReserveData(_asset)](src/BullStrategy.sol#L74)

src/BullStrategy.sol#L48-L85


 - [ ] ID-54
[RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543) ignores return value by [newStrat.deposit(assetsToDeploy,0)](src/RAYPVault.sol#L530)

src/RAYPVault.sol#L459-L543


 - [ ] ID-55
[OracleAggregator._clReadSigned(OracleAggregator.ChainlinkFeed)](src/OracleAggregator.sol#L414-L441) ignores return value by [(roundId,answer,None,updatedAt,answeredInRound) = f.feed.latestRoundData()](src/OracleAggregator.sol#L415-L421)

src/OracleAggregator.sol#L414-L441


 - [ ] ID-56
[BearStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24)](src/BearStrategy.sol#L43-L75) ignores return value by [IERC20(_usdc).approve(_aavePool,type()(uint256).max)](src/BearStrategy.sol#L72)

src/BearStrategy.sol#L43-L75


 - [ ] ID-57
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) ignores return value by [(None,None,None,None,None,healthFactor) = aavePool.getUserAccountData(address(this))](src/BullStrategy.sol#L316)

src/BullStrategy.sol#L303-L330


 - [ ] ID-58
[RAYPVault._deployToStrategy(uint256)](src/RAYPVault.sol#L739-L745) ignores return value by [strat.deposit(assets,0)](src/RAYPVault.sol#L744)

src/RAYPVault.sol#L739-L745


 - [ ] ID-59
[AaveMoneyMarketStrategy.constructor(address,address,address,uint8,address,address,address,address)](src/AaveMoneyMarketStrategy.sol#L30-L50) ignores return value by [IERC20(_asset).approve(_aavePool,type()(uint256).max)](src/AaveMoneyMarketStrategy.sol#L48)

src/AaveMoneyMarketStrategy.sol#L30-L50


 - [ ] ID-60
[RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543) ignores return value by [oldStrat.harvestAndReport()](src/RAYPVault.sol#L493)

src/RAYPVault.sol#L459-L543


 - [ ] ID-61
[BearStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24)](src/BearStrategy.sol#L43-L75) ignores return value by [IERC20(_asset).approve(_swapRouter,type()(uint256).max)](src/BearStrategy.sol#L71)

src/BearStrategy.sol#L43-L75


 - [ ] ID-62
[BearStrategy._harvestRewards()](src/BearStrategy.sol#L165-L192) ignores return value by [swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:address(rewardToken),tokenOut:address(usdc),fee:SWAP_FEE_TIER_HARVEST,recipient:address(this),amountIn:rewardAmount,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/BearStrategy.sol#L176-L184)

src/BearStrategy.sol#L165-L192


 - [ ] ID-63
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [IERC20(_usdc).approve(_aavePool,type()(uint256).max)](src/BullStrategy.sol#L82)

src/BullStrategy.sol#L48-L85


 - [ ] ID-64
[BullStrategy._getEthPrice18()](src/BullStrategy.sol#L334-L340) ignores return value by [(None,ethPrice,None,updatedAt,None) = priceFeed.latestRoundData()](src/BullStrategy.sol#L335)

src/BullStrategy.sol#L334-L340


 - [ ] ID-65
[AaveMoneyMarketStrategy.constructor(address,address,address,uint8,address,address,address,address)](src/AaveMoneyMarketStrategy.sol#L30-L50) ignores return value by [(None,None,None,None,None,None,None,None,_aToken,None,None,None,None,None,None) = IAavePool(_aavePool).getReserveData(_asset)](src/AaveMoneyMarketStrategy.sol#L45)

src/AaveMoneyMarketStrategy.sol#L30-L50


 - [ ] ID-66
[BullStrategy._flashLiquidateAll(uint256,uint256)](src/BullStrategy.sol#L244-L264) ignores return value by [aavePool.withdraw(asset,type()(uint256).max,address(this))](src/BullStrategy.sol#L247)

src/BullStrategy.sol#L244-L264


 - [ ] ID-67
[BearStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24)](src/BearStrategy.sol#L43-L75) ignores return value by [IERC20(_rewardToken).approve(_swapRouter,type()(uint256).max)](src/BearStrategy.sol#L74)

src/BearStrategy.sol#L43-L75


 - [ ] ID-68
[BullStrategy._flashLiquidate(uint256,uint256,uint256)](src/BullStrategy.sol#L223-L242) ignores return value by [swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:asset,tokenOut:address(usdc),fee:swapFeeTier,recipient:address(this),amountIn:wethNeeded,amountOutMinimum:totalOwed,sqrtPriceLimitX96:0}))](src/BullStrategy.sol#L231-L239)

src/BullStrategy.sol#L223-L242


 - [ ] ID-69
[BullStrategy._flashLiquidate(uint256,uint256,uint256)](src/BullStrategy.sol#L223-L242) ignores return value by [aavePool.repay(address(usdc),usdcAmount,2,address(this))](src/BullStrategy.sol#L224)

src/BullStrategy.sol#L223-L242


 - [ ] ID-70
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) ignores return value by [(None,price,None,updatedAt,None) = priceFeed.latestRoundData()](src/BullStrategy.sol#L324)

src/BullStrategy.sol#L303-L330


 - [ ] ID-71
[BearStrategy._checkProtocolHealth()](src/BearStrategy.sol#L194-L221) ignores return value by [(None,price,None,updatedAt,None) = priceFeed.latestRoundData()](src/BearStrategy.sol#L208)

src/BearStrategy.sol#L194-L221


 - [ ] ID-72
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [IERC20(_rewardToken).approve(_swapRouter,type()(uint256).max)](src/BullStrategy.sol#L84)

src/BullStrategy.sol#L48-L85


 - [ ] ID-73
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [IERC20(_asset).approve(_swapRouter,type()(uint256).max)](src/BullStrategy.sol#L81)

src/BullStrategy.sol#L48-L85


 - [ ] ID-74
[OracleAggregator._clRead(OracleAggregator.ChainlinkFeed)](src/OracleAggregator.sol#L386-L412) ignores return value by [(roundId,answer,None,updatedAt,answeredInRound) = f.feed.latestRoundData()](src/OracleAggregator.sol#L387-L393)

src/OracleAggregator.sol#L386-L412


 - [ ] ID-75
[BullStrategy._flashLiquidate(uint256,uint256,uint256)](src/BullStrategy.sol#L223-L242) ignores return value by [aavePool.withdraw(asset,wethToWithdraw,address(this))](src/BullStrategy.sol#L225)

src/BullStrategy.sol#L223-L242


 - [ ] ID-76
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [IERC20(_usdc).approve(_swapRouter,type()(uint256).max)](src/BullStrategy.sol#L83)

src/BullStrategy.sol#L48-L85


 - [ ] ID-77
[BullStrategy._flashLiquidateAll(uint256,uint256)](src/BullStrategy.sol#L244-L264) ignores return value by [swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:asset,tokenOut:address(usdc),fee:swapFeeTier,recipient:address(this),amountIn:wethNeeded,amountOutMinimum:totalOwed,sqrtPriceLimitX96:0}))](src/BullStrategy.sol#L253-L261)

src/BullStrategy.sol#L244-L264


 - [ ] ID-78
[BearStrategy._getEthPrice18()](src/BearStrategy.sol#L225-L231) ignores return value by [(None,ethPrice,None,updatedAt,None) = priceFeed.latestRoundData()](src/BearStrategy.sol#L226)

src/BearStrategy.sol#L225-L231


 - [ ] ID-79
[AaveMoneyMarketStrategy.constructor(address,address,address,uint8,address,address,address,address)](src/AaveMoneyMarketStrategy.sol#L30-L50) ignores return value by [IERC20(_rewardToken).approve(_swapRouter,type()(uint256).max)](src/AaveMoneyMarketStrategy.sol#L49)

src/AaveMoneyMarketStrategy.sol#L30-L50


 - [ ] ID-80
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) ignores return value by [(configWeth,None,None,None,None,None,None,None,None,None,None,None,None,None,None) = aavePool.getReserveData(asset)](src/BullStrategy.sol#L309)

src/BullStrategy.sol#L303-L330


 - [ ] ID-81
[BearStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24)](src/BearStrategy.sol#L43-L75) ignores return value by [IERC20(_usdc).approve(_swapRouter,type()(uint256).max)](src/BearStrategy.sol#L73)

src/BearStrategy.sol#L43-L75


 - [ ] ID-82
[BearStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24)](src/BearStrategy.sol#L43-L75) ignores return value by [(None,None,None,None,None,None,None,None,_aUSDC,None,None,None,None,None,None) = IAavePool(_aavePool).getReserveData(_usdc)](src/BearStrategy.sol#L68)

src/BearStrategy.sol#L43-L75


 - [ ] ID-83
[BullStrategy._flashLiquidateAll(uint256,uint256)](src/BullStrategy.sol#L244-L264) ignores return value by [aavePool.repay(address(usdc),debtBal,2,address(this))](src/BullStrategy.sol#L246)

src/BullStrategy.sol#L244-L264


 - [ ] ID-84
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [IERC20(_asset).approve(_aavePool,type()(uint256).max)](src/BullStrategy.sol#L80)

src/BullStrategy.sol#L48-L85


 - [ ] ID-85
[AaveMoneyMarketStrategy._harvestRewards()](src/AaveMoneyMarketStrategy.sol#L92-L119) ignores return value by [swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:address(rewardToken),tokenOut:asset,fee:SWAP_FEE_TIER,recipient:address(this),amountIn:rewardAmount,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/AaveMoneyMarketStrategy.sol#L103-L111)

src/AaveMoneyMarketStrategy.sol#L92-L119


 - [ ] ID-86
[RAYPVault.harvestStrategy()](src/RAYPVault.sol#L613-L623) ignores return value by [strat.harvestAndReport()](src/RAYPVault.sol#L616)

src/RAYPVault.sol#L613-L623


 - [ ] ID-87
[BullStrategy._harvestRewards()](src/BullStrategy.sol#L268-L299) ignores return value by [(None,amounts) = aaveRewards.claimAllRewards(tokens,address(this))](src/BullStrategy.sol#L273)

src/BullStrategy.sol#L268-L299


 - [ ] ID-88
[BullStrategy.constructor(address,address,address,address,address,address,address,address,address,uint24,uint256)](src/BullStrategy.sol#L48-L85) ignores return value by [(None,None,None,None,None,None,None,None,None,None,_debtUSDC,None,None,None,None) = IAavePool(_aavePool).getReserveData(_usdc)](src/BullStrategy.sol#L77)

src/BullStrategy.sol#L48-L85


 - [ ] ID-89
[BearStrategy._harvestRewards()](src/BearStrategy.sol#L165-L192) ignores return value by [(None,amounts) = aaveRewards.claimAllRewards(tokens,address(this))](src/BearStrategy.sol#L169)

src/BearStrategy.sol#L165-L192


 - [ ] ID-90
[AaveMoneyMarketStrategy._checkProtocolHealth()](src/AaveMoneyMarketStrategy.sol#L121-L144) ignores return value by [(configuration,None,None,None,None,None,None,None,None,None,None,None,None,None,None) = aavePool.getReserveData(asset)](src/AaveMoneyMarketStrategy.sol#L127)

src/AaveMoneyMarketStrategy.sol#L121-L144


 - [ ] ID-91
[BullStrategy._harvestRewards()](src/BullStrategy.sol#L268-L299) ignores return value by [swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:address(rewardToken),tokenOut:asset,fee:SWAP_FEE_TIER_HARVEST,recipient:address(this),amountIn:rewardAmount,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/BullStrategy.sol#L283-L291)

src/BullStrategy.sol#L268-L299


## missing-zero-check
Impact: Low
Confidence: Medium
 - [ ] ID-92
[OracleAggregator.constructor(address,address,address,address,address,address,bytes32,bytes32,address,uint8,uint256)._stableToken](src/OracleAggregator.sol#L219) lacks a zero-check on :
		- [stableToken = _stableToken](src/OracleAggregator.sol#L242)

src/OracleAggregator.sol#L219


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-93
Reentrancy in [RAYPVault.mint(uint256,address)](src/RAYPVault.sol#L259-L281):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L274)
	- [_deployToStrategy(assets)](src/RAYPVault.sol#L277)
		- [asset.approve(address(strat),assets)](src/RAYPVault.sol#L742)
		- [asset.transfer(address(strat),assets)](src/RAYPVault.sol#L743)
		- [strat.deposit(assets,0)](src/RAYPVault.sol#L744)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L278)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L278)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L278)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [_pushTwap()](src/RAYPVault.sol#L278)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)

src/RAYPVault.sol#L259-L281


 - [ ] ID-94
Reentrancy in [RAYPVault.harvestStrategy()](src/RAYPVault.sol#L613-L623):
	External calls:
	- [strat.harvestAndReport()](src/RAYPVault.sol#L616)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L622)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L622)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L622)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [harvestFees()](src/RAYPVault.sol#L620)
		- [balanceOf[to] += amount](src/RAYPVault.sol#L767)
	- [harvestFees()](src/RAYPVault.sol#L620)
		- [highWaterMark = convertToAssets(1e18)](src/RAYPVault.sol#L603)
	- [harvestFees()](src/RAYPVault.sol#L620)
		- [lastFeeHarvestAt = uint40(block.timestamp)](src/RAYPVault.sol#L604)
	- [_pushTwap()](src/RAYPVault.sol#L622)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)
	- [harvestFees()](src/RAYPVault.sol#L620)
		- [totalSupply += amount](src/RAYPVault.sol#L768)

src/RAYPVault.sol#L613-L623


 - [ ] ID-95
Reentrancy in [AaveMoneyMarketStrategy._liquidateAll()](src/AaveMoneyMarketStrategy.sol#L85-L90):
	External calls:
	- [assetsOut = aavePool.withdraw(asset,type()(uint256).max,address(this))](src/AaveMoneyMarketStrategy.sol#L88)
	State variables written after the call(s):
	- [totalDeposited = 0](src/AaveMoneyMarketStrategy.sol#L89)

src/AaveMoneyMarketStrategy.sol#L85-L90


 - [ ] ID-96
Reentrancy in [RAYPVault.mint(uint256,address)](src/RAYPVault.sol#L259-L281):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L274)
	State variables written after the call(s):
	- [_mint(receiver,shares)](src/RAYPVault.sol#L275)
		- [balanceOf[to] += amount](src/RAYPVault.sol#L767)

src/RAYPVault.sol#L259-L281


 - [ ] ID-97
Reentrancy in [BearStrategy._deploy(uint256)](src/BearStrategy.sol#L106-L120):
	External calls:
	- [usdcReceived = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:asset,tokenOut:address(usdc),fee:swapFeeTier,recipient:address(this),amountIn:assets,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/BearStrategy.sol#L107-L115)
	- [aavePool.supply(address(usdc),usdcReceived,address(this),0)](src/BearStrategy.sol#L117)
	State variables written after the call(s):
	- [totalDepositedUSDC += usdcReceived](src/BearStrategy.sol#L118)

src/BearStrategy.sol#L106-L120


 - [ ] ID-98
Reentrancy in [RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543):
	External calls:
	- [(healthy,reason) = oldStrat.healthCheck()](src/RAYPVault.sol#L478)
	- [oldStrat.harvestAndReport()](src/RAYPVault.sol#L493)
	- [assetsRecovered = oldStrat.withdrawAll(address(this),effectiveMin)](src/RAYPVault.sol#L504)
	- [_triggerEmergencyDrawdown(sharePriceAfterExit,dropBps)](src/RAYPVault.sol#L517)
		- [oldStrat.triggerEmergencyExit()](src/RAYPVault.sol#L760)
	- [asset.approve(address(newStrat),assetsToDeploy)](src/RAYPVault.sol#L528)
	- [asset.transfer(address(newStrat),assetsToDeploy)](src/RAYPVault.sol#L529)
	- [newStrat.deposit(assetsToDeploy,0)](src/RAYPVault.sol#L530)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L540)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L540)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L540)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [lastRebalanceAt = uint40(block.timestamp)](src/RAYPVault.sol#L536)
	- [lastRebalanceBlock = block.number](src/RAYPVault.sol#L535)
	- [_pushTwap()](src/RAYPVault.sol#L540)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)
	- [rebalanceCount += 1](src/RAYPVault.sol#L537)
	- [rebalanceLock = false](src/RAYPVault.sol#L534)

src/RAYPVault.sol#L459-L543


 - [ ] ID-99
Reentrancy in [RAYPVault.withdraw(uint256,address,address)](src/RAYPVault.sol#L289-L321):
	External calls:
	- [actual = strat.withdraw(assets,address(this),minOut)](src/RAYPVault.sol#L313)
	- [asset.transfer(treasury,fee)](src/RAYPVault.sol#L316)
	- [asset.transfer(receiver,actual - fee)](src/RAYPVault.sol#L317)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L319)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L319)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L319)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [_pushTwap()](src/RAYPVault.sol#L319)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)

src/RAYPVault.sol#L289-L321


 - [ ] ID-100
Reentrancy in [BullStrategy._deploy(uint256)](src/BullStrategy.sol#L121-L135):
	External calls:
	- [aavePool.supply(asset,assets,address(this),0)](src/BullStrategy.sol#L122)
	- [aavePool.setUserUseReserveAsCollateral(asset,true)](src/BullStrategy.sol#L123)
	- [aavePool.flashLoanSimple(address(this),address(usdc),usdcToBorrow,params,0)](src/BullStrategy.sol#L130)
	State variables written after the call(s):
	- [totalDeposited += assets](src/BullStrategy.sol#L133)

src/BullStrategy.sol#L121-L135


 - [ ] ID-101
Reentrancy in [BearStrategy._liquidate(uint256)](src/BearStrategy.sol#L122-L144):
	External calls:
	- [usdcWithdrawn = aavePool.withdraw(address(usdc),usdcNeeded,address(this))](src/BearStrategy.sol#L129)
	- [assetsOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:address(usdc),tokenOut:asset,fee:swapFeeTier,recipient:address(this),amountIn:usdcWithdrawn,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/BearStrategy.sol#L131-L139)
	State variables written after the call(s):
	- [totalDepositedUSDC = totalDepositedUSDC - usdcWithdrawn](src/BearStrategy.sol#L141-L143)
	- [totalDepositedUSDC = 0](src/BearStrategy.sol#L141-L143)

src/BearStrategy.sol#L122-L144


 - [ ] ID-102
Reentrancy in [BullStrategy._liquidate(uint256)](src/BullStrategy.sol#L137-L158):
	External calls:
	- [aavePool.flashLoanSimple(address(this),address(usdc),usdcToRepay,params,0)](src/BullStrategy.sol#L153)
	State variables written after the call(s):
	- [totalDeposited -= assets](src/BullStrategy.sol#L156)
	- [totalDeposited = 0](src/BullStrategy.sol#L157)

src/BullStrategy.sol#L137-L158


 - [ ] ID-103
Reentrancy in [RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543):
	External calls:
	- [(healthy,reason) = oldStrat.healthCheck()](src/RAYPVault.sol#L478)
	- [oldStrat.harvestAndReport()](src/RAYPVault.sol#L493)
	- [assetsRecovered = oldStrat.withdrawAll(address(this),effectiveMin)](src/RAYPVault.sol#L504)
	- [_triggerEmergencyDrawdown(sharePriceAfterExit,dropBps)](src/RAYPVault.sol#L517)
		- [oldStrat.triggerEmergencyExit()](src/RAYPVault.sol#L760)
	State variables written after the call(s):
	- [_triggerEmergencyDrawdown(sharePriceAfterExit,dropBps)](src/RAYPVault.sol#L517)
		- [emergencyTriggered = true](src/RAYPVault.sol#L754)

src/RAYPVault.sol#L459-L543


 - [ ] ID-104
Reentrancy in [BullStrategy._liquidateAll()](src/BullStrategy.sol#L160-L179):
	External calls:
	- [aavePool.flashLoanSimple(address(this),address(usdc),flashAmount,params,0)](src/BullStrategy.sol#L175)
	State variables written after the call(s):
	- [totalDeposited = 0](src/BullStrategy.sol#L178)

src/BullStrategy.sol#L160-L179


 - [ ] ID-105
Reentrancy in [RAYPVault.deposit(uint256,address)](src/RAYPVault.sol#L229-L254):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L246)
	State variables written after the call(s):
	- [_mint(receiver,shares)](src/RAYPVault.sol#L247)
		- [balanceOf[to] += amount](src/RAYPVault.sol#L767)

src/RAYPVault.sol#L229-L254


 - [ ] ID-106
Reentrancy in [BullStrategy._liquidateAll()](src/BullStrategy.sol#L160-L179):
	External calls:
	- [assetsOut = aavePool.withdraw(asset,type()(uint256).max,address(this))](src/BullStrategy.sol#L166)
	State variables written after the call(s):
	- [totalDeposited = 0](src/BullStrategy.sol#L167)

src/BullStrategy.sol#L160-L179


 - [ ] ID-107
Reentrancy in [AaveMoneyMarketStrategy._deploy(uint256)](src/AaveMoneyMarketStrategy.sol#L69-L73):
	External calls:
	- [aavePool.supply(asset,assets,address(this),0)](src/AaveMoneyMarketStrategy.sol#L70)
	State variables written after the call(s):
	- [totalDeposited += assets](src/AaveMoneyMarketStrategy.sol#L71)

src/AaveMoneyMarketStrategy.sol#L69-L73


 - [ ] ID-108
Reentrancy in [RAYPVault.redeem(uint256,address,address)](src/RAYPVault.sol#L326-L356):
	External calls:
	- [actual = strat.withdraw(assets,address(this),minOut)](src/RAYPVault.sol#L349)
	- [asset.transfer(treasury,fee)](src/RAYPVault.sol#L351)
	- [asset.transfer(receiver,actual - fee)](src/RAYPVault.sol#L352)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L354)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L354)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L354)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [_pushTwap()](src/RAYPVault.sol#L354)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)

src/RAYPVault.sol#L326-L356


 - [ ] ID-109
Reentrancy in [BaseStrategy.harvestAndReport()](src/BaseStrategy.sol#L194-L209):
	External calls:
	- [yieldHarvested = this._harvestRewardsExternal()](src/BaseStrategy.sol#L200-L208)
	State variables written after the call(s):
	- [lastHarvestTimestamp = uint40(block.timestamp)](src/BaseStrategy.sol#L201)

src/BaseStrategy.sol#L194-L209


 - [ ] ID-110
Reentrancy in [RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543):
	External calls:
	- [(healthy,reason) = oldStrat.healthCheck()](src/RAYPVault.sol#L478)
	State variables written after the call(s):
	- [rebalanceLock = true](src/RAYPVault.sol#L485)

src/RAYPVault.sol#L459-L543


 - [ ] ID-111
Reentrancy in [BullStrategy._liquidate(uint256)](src/BullStrategy.sol#L137-L158):
	External calls:
	- [assetsOut = aavePool.withdraw(asset,assets,address(this))](src/BullStrategy.sol#L142)
	State variables written after the call(s):
	- [totalDeposited -= assets](src/BullStrategy.sol#L143)
	- [totalDeposited = 0](src/BullStrategy.sol#L144)

src/BullStrategy.sol#L137-L158


 - [ ] ID-112
Reentrancy in [BearStrategy._liquidateAll()](src/BearStrategy.sol#L146-L163):
	External calls:
	- [usdcWithdrawn = aavePool.withdraw(address(usdc),type()(uint256).max,address(this))](src/BearStrategy.sol#L150)
	- [assetsOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({tokenIn:address(usdc),tokenOut:asset,fee:swapFeeTier,recipient:address(this),amountIn:usdcWithdrawn,amountOutMinimum:0,sqrtPriceLimitX96:0}))](src/BearStrategy.sol#L152-L160)
	State variables written after the call(s):
	- [totalDepositedUSDC = 0](src/BearStrategy.sol#L162)

src/BearStrategy.sol#L146-L163


 - [ ] ID-113
Reentrancy in [AaveMoneyMarketStrategy._liquidate(uint256)](src/AaveMoneyMarketStrategy.sol#L75-L83):
	External calls:
	- [assetsOut = aavePool.withdraw(asset,assets,address(this))](src/AaveMoneyMarketStrategy.sol#L76)
	State variables written after the call(s):
	- [totalDeposited -= assets](src/AaveMoneyMarketStrategy.sol#L79)
	- [totalDeposited = 0](src/AaveMoneyMarketStrategy.sol#L81)

src/AaveMoneyMarketStrategy.sol#L75-L83


 - [ ] ID-114
Reentrancy in [RAYPVault.deposit(uint256,address)](src/RAYPVault.sol#L229-L254):
	External calls:
	- [asset.transferFrom(msg.sender,address(this),assets)](src/RAYPVault.sol#L246)
	- [_deployToStrategy(assets)](src/RAYPVault.sol#L250)
		- [asset.approve(address(strat),assets)](src/RAYPVault.sol#L742)
		- [asset.transfer(address(strat),assets)](src/RAYPVault.sol#L743)
		- [strat.deposit(assets,0)](src/RAYPVault.sol#L744)
	State variables written after the call(s):
	- [_pushTwap()](src/RAYPVault.sol#L251)
		- [_twapBuffer[_twapHead] = convertToAssets(1e18)](src/RAYPVault.sol#L634)
	- [_pushTwap()](src/RAYPVault.sol#L251)
		- [_twapCount ++](src/RAYPVault.sol#L636)
	- [_pushTwap()](src/RAYPVault.sol#L251)
		- [_twapHead = uint8((_twapHead + 1) % 8)](src/RAYPVault.sol#L635)
	- [_pushTwap()](src/RAYPVault.sol#L251)
		- [lastTwapPush = uint40(block.timestamp)](src/RAYPVault.sol#L637)

src/RAYPVault.sol#L229-L254


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-115
Reentrancy in [BaseStrategy.withdrawAll(address,uint256)](src/BaseStrategy.sol#L157-L185):
	External calls:
	- [IERC20(asset).transfer(recipient,bal)](src/BaseStrategy.sol#L177)
	Event emitted after the call(s):
	- [Withdrawn(type()(uint256).max,assetsOut,0)](src/BaseStrategy.sol#L184)

src/BaseStrategy.sol#L157-L185


 - [ ] ID-116
Reentrancy in [RegimeDampener.pushRegime(uint8,uint256)](src/RegimeDampener.sol#L171-L214):
	External calls:
	- [_confirmRegime(REGIME_CRISIS,false,true)](src/RegimeDampener.sol#L187)
		- [vault.onRegimeConfirmed(newRegime,oldRegime)](src/RegimeDampener.sol#L312)
	Event emitted after the call(s):
	- [RegimePushed(label,confirmationCount,volatility,uint40(block.timestamp))](src/RegimeDampener.sol#L188)

src/RegimeDampener.sol#L171-L214


 - [ ] ID-117
Reentrancy in [BaseStrategy.harvestAndReport()](src/BaseStrategy.sol#L194-L209):
	External calls:
	- [yieldHarvested = this._harvestRewardsExternal()](src/BaseStrategy.sol#L200-L208)
	Event emitted after the call(s):
	- [HarvestFailed(reason)](src/BaseStrategy.sol#L207)
	- [Harvested(yieldHarvested,assetsAfterHarvest,uint40(block.timestamp))](src/BaseStrategy.sol#L203)

src/BaseStrategy.sol#L194-L209


 - [ ] ID-118
Reentrancy in [BaseStrategy.withdraw(uint256,address,uint256)](src/BaseStrategy.sol#L123-L147):
	External calls:
	- [IERC20(asset).transfer(recipient,assetsOut)](src/BaseStrategy.sol#L140)
	Event emitted after the call(s):
	- [Withdrawn(assets,assetsOut,slippageBps)](src/BaseStrategy.sol#L146)

src/BaseStrategy.sol#L123-L147


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-119
[OracleAggregator._clRead(OracleAggregator.ChainlinkFeed)](src/OracleAggregator.sol#L386-L412) uses timestamp for comparisons
	Dangerous comparisons:
	- [updatedAt > block.timestamp](src/OracleAggregator.sol#L399)
	- [block.timestamp - updatedAt > maxAge](src/OracleAggregator.sol#L403)

src/OracleAggregator.sol#L386-L412


 - [ ] ID-120
[OracleAggregator._clReadSigned(OracleAggregator.ChainlinkFeed)](src/OracleAggregator.sol#L414-L441) uses timestamp for comparisons
	Dangerous comparisons:
	- [updatedAt > block.timestamp](src/OracleAggregator.sol#L426)
	- [block.timestamp - updatedAt > maxAge](src/OracleAggregator.sol#L430)

src/OracleAggregator.sol#L414-L441


 - [ ] ID-121
[OracleAggregator._computeTwap()](src/OracleAggregator.sol#L522-L548) uses timestamp for comparisons
	Dangerous comparisons:
	- [slot.timestamp >= cutoff](src/OracleAggregator.sol#L535)
	- [block.timestamp > TWAP_WINDOW](src/OracleAggregator.sol#L525-L527)

src/OracleAggregator.sol#L522-L548


 - [ ] ID-122
[BullStrategy._getEthPrice18()](src/BullStrategy.sol#L334-L340) uses timestamp for comparisons
	Dangerous comparisons:
	- [ethPrice <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD](src/BullStrategy.sol#L336)

src/BullStrategy.sol#L334-L340


 - [ ] ID-123
[KeeperRegistry.ejectInactive(address)](src/KeeperRegistry.sol#L344-L373) uses timestamp for comparisons
	Dangerous comparisons:
	- [inactivityBreach = (k.lastRebalanceAt > 0 && block.timestamp - k.lastRebalanceAt > MAX_INACTIVITY) || (k.lastRebalanceAt == 0 && block.timestamp - k.registeredAt > MAX_INACTIVITY)](src/KeeperRegistry.sol#L348-L354)

src/KeeperRegistry.sol#L344-L373


 - [ ] ID-124
[KeeperRegistry.cooldownRemaining()](src/KeeperRegistry.sol#L445-L449) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= available](src/KeeperRegistry.sol#L447)

src/KeeperRegistry.sol#L445-L449


 - [ ] ID-125
[RegimeDampener.pushRegime(uint8,uint256)](src/RegimeDampener.sol#L171-L214) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < nextAllowed](src/RegimeDampener.sol#L180)

src/RegimeDampener.sol#L171-L214


 - [ ] ID-126
[KeeperRegistry.withdraw()](src/KeeperRegistry.sol#L224-L241) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < unbondingEndsAt](src/KeeperRegistry.sol#L229)

src/KeeperRegistry.sol#L224-L241


 - [ ] ID-127
[RAYPVault.harvestFees()](src/RAYPVault.sol#L578-L607) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(block.timestamp >= lastFeeHarvestAt + FEE_HARVEST_INTERVAL,harvest too soon)](src/RAYPVault.sol#L579-L582)

src/RAYPVault.sol#L578-L607


 - [ ] ID-128
[RAYPVault._pushTwap()](src/RAYPVault.sol#L632-L638) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < lastTwapPush + TWAP_PUSH_INTERVAL](src/RAYPVault.sol#L633)

src/RAYPVault.sol#L632-L638


 - [ ] ID-129
[BearStrategy._checkProtocolHealth()](src/BearStrategy.sol#L194-L221) uses timestamp for comparisons
	Dangerous comparisons:
	- [price <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD](src/BearStrategy.sol#L209)

src/BearStrategy.sol#L194-L221


 - [ ] ID-130
[KeeperRegistry.executeRebalance(uint256)](src/KeeperRegistry.sol#L262-L307) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < availableAt](src/KeeperRegistry.sol#L274)

src/KeeperRegistry.sol#L262-L307


 - [ ] ID-131
[BearStrategy._getEthPrice18()](src/BearStrategy.sol#L225-L231) uses timestamp for comparisons
	Dangerous comparisons:
	- [ethPrice <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD](src/BearStrategy.sol#L227)

src/BearStrategy.sol#L225-L231


 - [ ] ID-132
[RAYPVault.harvestStrategy()](src/RAYPVault.sol#L613-L623) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= lastFeeHarvestAt + FEE_HARVEST_INTERVAL](src/RAYPVault.sol#L619)

src/RAYPVault.sol#L613-L623


 - [ ] ID-133
[BullStrategy._checkProtocolHealth()](src/BullStrategy.sol#L303-L330) uses timestamp for comparisons
	Dangerous comparisons:
	- [price <= 0 || block.timestamp - updatedAt > STALENESS_THRESHOLD](src/BullStrategy.sol#L325)

src/BullStrategy.sol#L303-L330


## assembly
Impact: Informational
Confidence: High
 - [ ] ID-134
[KeeperRegistry.executeRebalance(uint256)](src/KeeperRegistry.sol#L262-L307) uses assembly
	- [INLINE ASM](src/KeeperRegistry.sol#L305)

src/KeeperRegistry.sol#L262-L307


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-135
[RAYPVault.executeRebalance(uint8,uint256)](src/RAYPVault.sol#L459-L543) has a high cyclomatic complexity (13).

src/RAYPVault.sol#L459-L543


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-136
Low level call in [KeeperRegistry.withdraw()](src/KeeperRegistry.sol#L224-L241):
	- [(ok,None) = msg.sender.call{value: stakeToReturn}()](src/KeeperRegistry.sol#L237)

src/KeeperRegistry.sol#L224-L241


 - [ ] ID-137
Low level call in [OracleAggregator._readStableDominance()](src/OracleAggregator.sol#L552-L570):
	- [(ok,data) = stableToken.staticcall(abi.encodeWithSignature(totalSupply()))](src/OracleAggregator.sol#L557-L559)

src/OracleAggregator.sol#L552-L570


 - [ ] ID-138
Low level call in [KeeperRegistry.sweepSlashedFunds(address)](src/KeeperRegistry.sol#L379-L394):
	- [(ok,None) = to.call{value: amount}()](src/KeeperRegistry.sol#L390)

src/KeeperRegistry.sol#L379-L394


 - [ ] ID-139
Low level call in [OracleAggregator.updatePythFeeds(bytes[])](src/OracleAggregator.sol#L330-L343):
	- [(ok,None) = msg.sender.call{value: msg.value - fee}()](src/OracleAggregator.sol#L340)

src/OracleAggregator.sol#L330-L343


## missing-inheritance
Impact: Informational
Confidence: High
 - [ ] ID-140
[KeeperRegistry](src/KeeperRegistry.sol#L62-L467) should inherit from [IRAYPVault](src/KeeperRegistry.sol#L51-L55)

src/KeeperRegistry.sol#L62-L467


 - [ ] ID-141
[RAYPVault](src/RAYPVault.sol#L92-L789) should inherit from [IRAYPVault](src/RegimeDampener.sol#L38-L40)

src/RAYPVault.sol#L92-L789


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-142
Parameter [KeeperRegistry.setParameters(uint256,uint256,uint16)._keeperFee](src/KeeperRegistry.sol#L406) is not in mixedCase

src/KeeperRegistry.sol#L406


 - [ ] ID-143
Parameter [KeeperRegistry.setTreasury(address)._treasury](src/KeeperRegistry.sol#L426) is not in mixedCase

src/KeeperRegistry.sol#L426


 - [ ] ID-144
Parameter [RAYPVault.setParameters(uint16,uint16,uint16,uint16)._perfFeeBps](src/RAYPVault.sol#L677) is not in mixedCase

src/RAYPVault.sol#L677


 - [ ] ID-145
Parameter [RegimeDampener.setVault(address)._vault](src/RegimeDampener.sol#L251) is not in mixedCase

src/RegimeDampener.sol#L251


 - [ ] ID-146
Function [BaseStrategy._safeTotalAssets()](src/BaseStrategy.sol#L262-L264) is not in mixedCase

src/BaseStrategy.sol#L262-L264


 - [ ] ID-147
Parameter [RAYPVault.setParameters(uint16,uint16,uint16,uint16)._maxDrawdownBps](src/RAYPVault.sol#L680) is not in mixedCase

src/RAYPVault.sol#L680


 - [ ] ID-148
Parameter [RAYPVault.setRegimeDampener(address)._dampener](src/RAYPVault.sol#L700) is not in mixedCase

src/RAYPVault.sol#L700


 - [ ] ID-149
Parameter [KeeperRegistry.setParameters(uint256,uint256,uint16)._minStake](src/KeeperRegistry.sol#L405) is not in mixedCase

src/KeeperRegistry.sol#L405


 - [ ] ID-150
Parameter [RAYPVault.setTreasury(address)._treasury](src/RAYPVault.sol#L695) is not in mixedCase

src/RAYPVault.sol#L695


 - [ ] ID-151
Parameter [RAYPVault.setParameters(uint16,uint16,uint16,uint16)._withdrawalFeeBps](src/RAYPVault.sol#L678) is not in mixedCase

src/RAYPVault.sol#L678


 - [ ] ID-152
Function [BaseStrategy._harvestRewardsExternal()](src/BaseStrategy.sol#L216-L219) is not in mixedCase

src/BaseStrategy.sol#L216-L219


 - [ ] ID-153
Parameter [KeeperRegistry.setVault(address)._vault](src/KeeperRegistry.sol#L421) is not in mixedCase

src/KeeperRegistry.sol#L421


 - [ ] ID-154
Parameter [KeeperRegistry.setParameters(uint256,uint256,uint16)._slashBps](src/KeeperRegistry.sol#L407) is not in mixedCase

src/KeeperRegistry.sol#L407


 - [ ] ID-155
Parameter [RAYPVault.setParameters(uint16,uint16,uint16,uint16)._maxSlippageBps](src/RAYPVault.sol#L679) is not in mixedCase

src/RAYPVault.sol#L679


## immutable-states
Impact: Optimization
Confidence: High
 - [ ] ID-156
[OracleAggregator.stableToken](src/OracleAggregator.sol#L150) should be immutable 

src/OracleAggregator.sol#L150


 - [ ] ID-157
[OracleAggregator.pyth](src/OracleAggregator.sol#L142) should be immutable 

src/OracleAggregator.sol#L142


 - [ ] ID-158
[OracleAggregator.pythPriceId](src/OracleAggregator.sol#L143) should be immutable 

src/OracleAggregator.sol#L143


 - [ ] ID-159
[BaseStrategy.guardian](src/BaseStrategy.sol#L42) should be immutable 

src/BaseStrategy.sol#L42


 - [ ] ID-160
[OracleAggregator.pythVolId](src/OracleAggregator.sol#L144) should be immutable 

src/OracleAggregator.sol#L144


 - [ ] ID-161
[OracleAggregator.stableDecimals](src/OracleAggregator.sol#L152) should be immutable 

src/OracleAggregator.sol#L152


