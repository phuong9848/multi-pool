# Inspiration
Based on the design of Balancer on Ethereum, we propose a solution of a multi token pool for LST specifically. We have seen Aptos is a rich Liquid Staking platform, but lacks of a pool / vault that harnesses all these liquidity, so we have choosen the Multi Token Pool model to solve this problem.
# High-Level Architecture
`MultiStak` is a multi-token pool specifically designed for Liquid Staking Tokens (`LST`) on the **Aptos** platform. Drawing inspiration from the Balancer protocol on Ethereum, `MultiStak` aims to consolidate the liquidity from various `LSTs` into a unified pool. This allows for efficient swapping, liquidity addition, and overall better management of liquid assets in the staking ecosystem.
# How It Is Built
`MultiStak` leverages the robust design principles of the Balancer protocol but tailors them to suit the unique needs of the **Aptos** blockchain. Key components include:
- **Token Pool**: Supports up to 5 different `LSTs`, allowing users to provide liquidity and earn fees.
- **Swap Mechanism**: Facilitated by an AMM that dynamically adjusts token prices based on supply and demand.
- **Liquidity Provision**: Users can add or remove liquidity from the pool, receiving pool tokens representing their share.
# In-depth Architecture
![image](https://github.com/user-attachments/assets/9c8d6b4c-1fa6-40b8-b75d-83e71ad7ed3b)
# Key Equations and Mechanisms:
- **Pool Value Calculation**:
   
$$
  V = \prod_t B_t^{W_t}
$$
  - **V**: Constant
  - **B**: Balance of asset `t`
  - **W**: Weight of asset `t`
# Create Pool
Creating a pool on `MultiStak` involves the following steps:
1. **Initializ Pool**: A new pool is initialized via the factory, setting the initial swap fees.
2. **Bind Tokens**: Define the initial balances, weights of each `LST` then bind to pool.
3. **Finalize**: Once the parameters are set, the pool is finalized and ready to accept liquidity and perform swaps.
# Swap
Swapping tokens within the `MultiStak` pool is facilitated by the AMM. User specifies the token they wish to swap or they wish to receive. Then, the pool calculates the amount of Token that the user will receive based on the current pool balances and weights. The tokens are swapped, and the new balances are updated in the pool.

# Join Pool via Add Liquidity and Receive LP Token
Adding liquidity to the `MultiStak` pool allows users to earn a share of the trading fees. User deposits a mix of the pool's tokens in proportion to their weights. Then, The pool mints new `LP` (liquidity provider) tokens to the user, representing their share of the pool.As trades occur within the pool, fees are collected and distributed to `LP` token holders.
