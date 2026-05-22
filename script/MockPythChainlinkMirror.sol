// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IChainlinkAggregator {
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    );
    function decimals() external view returns (uint8);
}

/// @title  MockPythChainlinkMirror
/// @notice Testnet-only mock IPyth that mirrors a Chainlink price feed for the
///         configured price ID (so price consensus is guaranteed by
///         construction) and returns a fixed sane vol payload for the vol ID.
///         The prior MockPyth returned the same hardcoded payload for every
///         feed ID, causing OracleAggregator to revert with VolOutOfRange or
///         PriceDiverged whenever Chainlink moved.
contract MockPythChainlinkMirror {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }

    IChainlinkAggregator public immutable chainlinkPrice;
    bytes32 public immutable priceId;
    bytes32 public immutable volId;
    int32   public immutable chainlinkExpo;   // Pyth-style negative expo derived from CL decimals
    uint64  public immutable priceConfBps;    // conf as bps of price, e.g. 10 = 0.10%

    int64   public immutable volPrice;        // raw vol price (with volExpo)
    uint64  public immutable volConf;
    int32   public immutable volExpo;

    error UnknownFeed(bytes32 id);
    error ChainlinkOverflow(int256 answer);
    error NegativePrice(int256 answer);

    constructor(
        address _chainlinkPrice,
        bytes32 _priceId,
        bytes32 _volId,
        uint64  _priceConfBps,
        int64   _volPrice,
        uint64  _volConf,
        int32   _volExpo
    ) {
        chainlinkPrice = IChainlinkAggregator(_chainlinkPrice);
        priceId        = _priceId;
        volId          = _volId;
        chainlinkExpo  = -int32(uint32(IChainlinkAggregator(_chainlinkPrice).decimals()));
        priceConfBps   = _priceConfBps;
        volPrice       = _volPrice;
        volConf        = _volConf;
        volExpo        = _volExpo;
    }

    function getPriceNoOlderThan(bytes32 id, uint /* age */) external view returns (Price memory) {
        if (id == priceId) {
            (, int256 answer, , uint256 updatedAt, ) = chainlinkPrice.latestRoundData();
            if (answer <= 0) revert NegativePrice(answer);
            if (answer > type(int64).max) revert ChainlinkOverflow(answer);
            uint64 conf = uint64(uint256(answer) * priceConfBps / 10_000);
            return Price(int64(answer), conf, chainlinkExpo, updatedAt);
        }
        if (id == volId) {
            return Price(volPrice, volConf, volExpo, block.timestamp);
        }
        revert UnknownFeed(id);
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function getUpdateFee(bytes[] calldata) external pure returns (uint) {
        return 0;
    }
}
