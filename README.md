# FlightBookingNFT Smart Contract

This smart contract implements an NFT-based flight ticketing and resale marketplace with cross-chain capabilities. It leverages Chainlink services for dynamic pricing and secure cross-chain messaging.

## Features
- NFT flight tickets (ERC721)
- Dynamic pricing using Chainlink Price Feeds
- Resale marketplace for tickets
- Cross-chain ticket transfers using Chainlink CCIP
- Admin controls for allowlisting and pausing

---

## Chainlink Integrations

### 1. Chainlink Price Feed
- **Purpose:** Fetches real-time AVAX/USD price to set ticket prices dynamically.
- **Where Used:**
  - Declared as `AggregatorV3Interface internal priceFeed;`
  - Initialized in the constructor:
    ```solidity
    priceFeed = AggregatorV3Interface(FUJI_AVAX_USD);
    ```
  - Used in `mintFlightTicket()` to determine the current ticket price:
    ```solidity
    uint256 currentPrice = getCurrentPrice();
    ```
  - The `getCurrentPrice()` function fetches the latest price:
    ```solidity
    (, int256 price, , , ) = priceFeed.latestRoundData();
    return uint256(price) * 10**10; // Convert to 18 decimals
    ```
- **Type:** Price Feed

---

### 2. Chainlink CCIP (Cross-Chain Interoperability Protocol)
- **Purpose:** Enables secure cross-chain NFT transfers and message passing.
- **Where Used:**
  - The contract inherits from `CCIPReceiver`:
    ```solidity
    contract FlightBookingNFT is ... CCIPReceiver
    ```
  - Initialized in the constructor:
    ```solidity
    CCIPReceiver(_router)
    ```
  - Sending cross-chain messages in `transferTicketCrossChain()`:
    ```solidity
    Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({...});
    IRouterClient router = IRouterClient(this.getRouter());
    uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);
    router.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);
    ```
  - Receiving cross-chain messages in `_ccipReceive()`:
    ```solidity
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override
    ```
- **Type:** CCIP (Cross-Chain Messaging)

---

## Quick Start
1. Install dependencies (OpenZeppelin, Chainlink).
2. Deploy with router address and initial owner.
3. Mint tickets using `mintFlightTicket`.
4. List for resale or transfer cross-chain as needed.

---

## Security
- Only allowlisted chains and senders can interact cross-chain.
- Tickets cannot be resold or transferred after use or after flight departure.

---

## License
MIT 