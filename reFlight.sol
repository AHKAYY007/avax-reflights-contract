// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

contract FlightBookingNFT is ERC721URIStorage, Ownable, CCIPReceiver {
    using Client for Client.EVM2AnyMessage;
    
    uint256 private _tokenIdCounter;
    
    // Price feed for dynamic pricing
    AggregatorV3Interface internal priceFeed;

    address constant FUJI_AVAX_USD = 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD;
    
    // Flight ticket structure
    struct FlightTicket {
        string flightNumber;
        string departure;
        string destination;
        uint256 departureTime;
        uint256 arrivalTime;
        string seatClass;
        uint256 originalPrice;
        bool isResellable;
        bool isUsed;
        address originalBuyer;
        uint256 listingTime;
    }
    
    // Resale marketplace
    struct ResaleListing {
        uint256 tokenId;
        uint256 price;
        address seller;
        bool isActive;
        uint256 listedAt;
    }
    
    // Storage mappings
    mapping(uint256 => FlightTicket) public flightTickets;
    mapping(uint256 => ResaleListing) public resaleListings;
    mapping(uint256 => bool) public isListedForResale;
    
    // Cross-chain support
    mapping(uint64 => bool) public allowlistedChains;
    mapping(address => bool) public allowlistedSenders;
    
    // Events
    event TicketMinted(
        uint256 indexed tokenId, 
        address indexed buyer, 
        string flightNumber,
        uint256 price
    );
    
    event TicketListedForResale(
        uint256 indexed tokenId, 
        uint256 price, 
        address indexed seller
    );
    
    event TicketResold(
        uint256 indexed tokenId, 
        address indexed from, 
        address indexed to, 
        uint256 price
    );
    
    event CrossChainTransferInitiated(
        uint256 indexed tokenId,
        uint64 destinationChain,
        address recipient
    );
    
    event MessageReceived(
        bytes32 messageId, 
        uint64 sourceChainSelector
    ); 

    // Constructor
    constructor(
        address _router,
        //address _priceFeed,
        address initialOwner
    ) 
        ERC721("Flight Ticket NFT", "FLIGHT") 
        Ownable(initialOwner)
        CCIPReceiver(_router)
    {
        priceFeed = AggregatorV3Interface(FUJI_AVAX_USD);
    }
    
    function mintFlightTicket(
        address to,
        string memory flightNumber,
        string memory departure,
        string memory destination,
        uint256 departureTime,
        uint256 arrivalTime,
        string memory seatClass,
        string memory tokenURI
    ) external payable returns (uint256) {
        require(departureTime > block.timestamp, "Departure time must be in future");
        require(arrivalTime > departureTime, "Invalid arrival time");
        
        // Get current price from Chainlink price feed
        uint256 currentPrice = getCurrentPrice();
        require(msg.value >= currentPrice, "Insufficient payment");
        
        uint256 tokenId = _tokenIdCounter++;
        
        // Mint the NFT
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
        
        // Store flight data
        flightTickets[tokenId] = FlightTicket({
            flightNumber: flightNumber,
            departure: departure,
            destination: destination,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            seatClass: seatClass,
            originalPrice: currentPrice,
            isResellable: true,
            isUsed: false,
            originalBuyer: to,
            listingTime: block.timestamp
        });
        
        emit TicketMinted(tokenId, to, flightNumber, currentPrice);
        
        // Refund excess payment
        if (msg.value > currentPrice) {
            payable(msg.sender).transfer(msg.value - currentPrice);
        }
        
        return tokenId;
    }
    
    function listTicketForResale(uint256 tokenId, uint256 price) external {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(!flightTickets[tokenId].isUsed, "Ticket already used");
        require(flightTickets[tokenId].isResellable, "Ticket not resellable");
        require(block.timestamp < flightTickets[tokenId].departureTime, "Flight already departed");
        require(!isListedForResale[tokenId], "Already listed");
        require(price > 0, "Price must be greater than 0");
        
        isListedForResale[tokenId] = true;
        resaleListings[tokenId] = ResaleListing({
            tokenId: tokenId,
            price: price,
            seller: msg.sender,
            isActive: true,
            listedAt: block.timestamp
        });
        
        emit TicketListedForResale(tokenId, price, msg.sender);
    }
    
    function buyResaleTicket(uint256 tokenId) external payable {
        ResaleListing storage listing = resaleListings[tokenId];
        require(listing.isActive, "Listing not active");
        require(msg.value >= listing.price, "Insufficient payment");
        require(!flightTickets[tokenId].isUsed, "Ticket already used");
        require(block.timestamp < flightTickets[tokenId].departureTime, "Flight already departed");
        
        address seller = listing.seller;
        uint256 price = listing.price;
        
        // Clear the listing
        listing.isActive = false;
        isListedForResale[tokenId] = false;
        
        // Transfer the NFT
        _transfer(seller, msg.sender, tokenId);
        
        // Calculate platform fee (2.5%)
        uint256 platformFee = (price * 25) / 1000;
        uint256 sellerAmount = price - platformFee;
        
        // Transfer payments
        payable(seller).transfer(sellerAmount);
        payable(owner()).transfer(platformFee);
        
        // Refund excess
        if (msg.value > price) {
            payable(msg.sender).transfer(msg.value - price);
        }
        
        emit TicketResold(tokenId, seller, msg.sender, price);
    }
    
    function cancelResaleListing(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(isListedForResale[tokenId], "Not listed for resale");
        
        resaleListings[tokenId].isActive = false;
        isListedForResale[tokenId] = false;
    }
    
    function useTicket(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(!flightTickets[tokenId].isUsed, "Ticket already used");
        require(
            block.timestamp >= flightTickets[tokenId].departureTime - 3600, // 1 hour before
            "Too early to use ticket"
        );
        
        flightTickets[tokenId].isUsed = true;
        
        // Remove from resale if listed
        if (isListedForResale[tokenId]) {
            isListedForResale[tokenId] = false;
            resaleListings[tokenId].isActive = false;
        }
    }
    
    // CROSS-CHAIN FUNCTIONS    
    function transferTicketCrossChain(
        uint256 tokenId,
        uint64 destinationChainSelector,
        address recipient
    ) external payable {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        require(allowlistedChains[destinationChainSelector], "Chain not allowlisted");
        require(!flightTickets[tokenId].isUsed, "Ticket already used");
        
        // Remove from resale if listed
        if (isListedForResale[tokenId]) {
            isListedForResale[tokenId] = false;
            resaleListings[tokenId].isActive = false;
        }
        
        // Prepare cross-chain message
        bytes memory data = abi.encode(
            tokenId,
            flightTickets[tokenId],
            recipient
        );
        
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(this)),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0) // Pay in native token
        });
        
        // Get fee
        IRouterClient router = IRouterClient(this.getRouter());
        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);
        require(msg.value >= fees, "Insufficient fee for cross-chain transfer");
        
        // Burn the NFT on source chain
        _burn(tokenId);
        
        // Send cross-chain message
        router.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);
        
        emit CrossChainTransferInitiated(tokenId, destinationChainSelector, recipient);
        
        // Refund excess
        if (msg.value > fees) {
            payable(msg.sender).transfer(msg.value - fees);
        }
    }
    
    // CCIP RECEIVER IMPLEMENTATION    
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        bytes32 messageId = any2EvmMessage.messageId;
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector;
        address sender = abi.decode(any2EvmMessage.sender, (address));
        
        require(allowlistedSenders[sender], "Sender not allowlisted");
        
        // Decode the received data
        (uint256 tokenId, FlightTicket memory ticket, address recipient) = 
            abi.decode(any2EvmMessage.data, (uint256, FlightTicket, address));
        
        // Mint the NFT on destination chain
        _safeMint(recipient, tokenId);
        
        // Restore flight ticket data
        flightTickets[tokenId] = ticket;

        emit MessageReceived(messageId, sourceChainSelector);
    }
    
    // UTILITY FUNCTIONS    
    function getCurrentPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * 10**10; // Convert to 18 decimals
    }
    
    function getFlightTicket(uint256 tokenId) external view returns (FlightTicket memory) {
        require(_exists(tokenId), "Token does not exist");
        return flightTickets[tokenId];
    }
    
    function getResaleListing(uint256 tokenId) external view returns (ResaleListing memory) {
        return resaleListings[tokenId];
    }
    
    function getAllActiveListings() external view returns (uint256[] memory) {
        uint256[] memory activeListings = new uint256[](_tokenIdCounter);
        uint256 count = 0;
        
        for (uint256 i = 0; i < _tokenIdCounter; i++) {
            if (isListedForResale[i] && resaleListings[i].isActive) {
                activeListings[count] = i;
                count++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = activeListings[i];
        }
        
        return result;
    }
    
    // ADMIN FUNCTIONS
    function allowlistDestinationChain(uint64 chainSelector, bool allowed) external onlyOwner {
        allowlistedChains[chainSelector] = allowed;
    }
    
    function allowlistSender(address sender, bool allowed) external onlyOwner {
        allowlistedSenders[sender] = allowed;
    }
    
    // function updatePriceFeed(address newPriceFeed) external onlyOwner {
    //     priceFeed = AggregatorV3Interface(newPriceFeed);
    // }
    
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function emergencyPause(uint256 tokenId) external onlyOwner {
        flightTickets[tokenId].isResellable = false;
        if (isListedForResale[tokenId]) {
            isListedForResale[tokenId] = false;
            resaleListings[tokenId].isActive = false;
        }
    }
    
    // REQUIRED OVERRIDES
    function _exists(uint256 tokenId) internal view returns (bool) {
        return tokenId < _tokenIdCounter && _ownerOf(tokenId) != address(0);
    }
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(ERC721URIStorage, CCIPReceiver) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
    
    // Receive function for payments
    receive() external payable {}

    // function onERC1155Received(address operator, address from, uint256[] memory ids, uint256[] memory values, bytes calldata data) external pure returns(bytes4){
    // return this.onERC1155BatchReceived(operator,from,ids,value,data);
    // }
}