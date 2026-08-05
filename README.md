# Ethena Loop on Aave V3 — Growth Assignment

Reproducible working behind the memo: the Ethena (USDe/sUSDe) loop on Aave V3 Ethereum Core — mechanics, who's running it, and DAO revenue/curve implications.

## Structure

```
notebook/
  00_setup_data_sourcing.ipynb        Contract addresses, market/reserve identity checks, E-mode
                                       category selection, on-chain parameter table (Section 0)
  01_q1_loop_mechanics_leverage_roe.ipynb   Q1 — loop mechanics, yield source, max leverage, ROE
  02_q2_who_are_loopers.ipynb               Q2 — who's running the loop, leverage, concentration, risk
  04_q4_revenue_curve_configs.ipynb         Q4 — DAO revenue, equilibrium utilization, curve configs
queries/
  02_q2_loopers_filtered_by_ltv.sql             Dune SQL, cross-check for Section 2.8 of notebook 02
  03_q3_carry_utilisation_supply_borrow_v3.sql  Dune SQL for Q3 (no corresponding local notebook)
```

Each notebook is self-contained — it makes its own RPC calls rather than importing state from another notebook's kernel. Numbers pulled from one notebook into another (e.g. the top-10 looper cluster reused in notebook 04) are copied in as hardcoded values with a citation to the source section, not computed live. You can run any notebook on its own, but **00 → 01 → 02 → 04** is the intended reading/run order.

The two `.sql` files are Dune Analytics queries, not part of the Python environment — see [Running the Dune queries](#running-the-dune-queries) below.

## Requirements

- Python 3.10+
- Internet access to a public Ethereum RPC (no API key needed)

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Running the notebooks

```bash
jupyter lab notebook/
```

Open a notebook and **Run All**. A few things to know:

- **Pinned block.** Every notebook reads on-chain state at a fixed block (`BLOCK_NUMBER = 25682519`), not `latest`, so re-running reproduces the same numbers regardless of when you run it. Only the RPC's ability to serve that historical state can change — see below.
- **RPC endpoint.** Defaults to the public archive endpoint `https://eth.drpc.org`. If it's down or rate-limiting, swap in the fallback commented next to `RPC = ...` in each notebook's setup cell (`https://eth-mainnet.public.blastapi.io`), or any other archive node you have access to. A non-archive/"full" node will fail on the pinned block once it prunes that state.
- **Runtime.** Notebooks 00, 01, and 04 run in well under a minute. Notebook 02 is the slow one — its first cell pages through the complete `Transfer` event history for two tokens back to block 0, in ≤10,000-block windows (`rpc.mevblocker.io`'s enforced range cap), which is roughly 2,600 sequential `eth_getLogs` calls per token. Expect this cell alone to take **10–20 minutes** on a public endpoint; the rest of the notebook (batching ~18,000 balance/account-data calls through Multicall3) adds only another minute or two. If you see `429`/rate-limit or connection errors, the notebook already retries with exponential backoff; persistent failures usually mean the RPC needs a break or a different endpoint.
- **No API keys required.** Etherscan lookups referenced in the markdown (e.g. wallet tx history, name tags) were done manually in a browser and aren't scripted — the on-chain calls that *are* scripted only need RPC access.

## Running the Dune queries

The two `.sql` files are written for [Dune Analytics](https://dune.com) and aren't executable locally:

Dashboards are available to view at:
Q2: https://dune.com/kevinlcai/usde-largest-loopers
Q3: https://dune.com/kevinlcai/ethena-carry-dashboard