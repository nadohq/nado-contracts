// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @dev Each clearinghouse has a unique quote product
uint32 constant QUOTE_PRODUCT_ID = 0;

/// @dev Fees account
bytes32 constant FEES_ACCOUNT = bytes32(0);
bytes32 constant X_ACCOUNT = 0x0000000000000000000000000000000000000000000000000000000000000001;
bytes32 constant N_ACCOUNT = 0x0000000000000000000000000000000000000000000000000000000000000002;
bytes32 constant NLP_POOL_ACCOUNT_START = 0x0000000000000000000000000000000000000000000000000000000100000000;

string constant DEFAULT_REFERRAL_CODE = "-1";

uint128 constant MINIMUM_LIQUIDITY = 10**3;

int128 constant ONE = 10**18;

uint8 constant MAX_DECIMALS = 18;

int128 constant TAKER_SEQUENCER_FEE = 0; // $0.00

int128 constant SLOW_MODE_FEE = 1000000; // $1

int128 constant FAST_WITHDRAWAL_FEE_RATE = 1_000_000_000_000_000; // 0.1%

int128 constant LIQUIDATION_FEE = 1e18; // $1
int128 constant HEALTHCHECK_FEE = 1e18; // $1

uint128 constant INT128_MAX = uint128(type(int128).max);

uint64 constant SECONDS_PER_DAY = 3600 * 24;

uint32 constant VRTX_PRODUCT_ID = 41;

int128 constant LIQUIDATION_FEE_FRACTION = 500_000_000_000_000_000; // 50%

int128 constant INTEREST_FEE_FRACTION = 200_000_000_000_000_000; // 20%

int256 constant MIN_DEPOSIT_AMOUNT = ONE / 10; // $0.1

int256 constant MIN_FIRST_DEPOSIT_AMOUNT = 5 * ONE; // $5

uint32 constant MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS = 10;

uint32 constant NLP_PRODUCT_ID = 11;

uint96 constant MASK_6_BYTES = 0xFFFFFFFFFFFF000000000000;

uint64 constant SLOW_MODE_TX_DELAY = 3 * 24 * 60 * 60; // 3 days

uint64 constant NLP_LOCK_PERIOD = 4 * 24 * 60 * 60; // 4 days

int128 constant INF = type(int128).max / 128;

int128 constant MIN_SPREAD_LIQ_PENALTY_X18 = ONE / 400; // 0.25%

int128 constant MIN_NON_SPREAD_LIQ_PENALTY_X18 = ONE / 200; // 0.5%

int128 constant TAKER_FEE_ACCRUAL_RATE_X18 = -300_000_000_000_000; // -3bps
