// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title FlipSki V2 - Unified Multi-Token Coin Flip Game On Base
 * @dev A unified contract for coin flip games supporting both ETH and custom ERC20 tokens
 * @author qdibs
 * 
 *  _____                                        _____ 
 *( ___ )                                      ( ___ )
 * |   |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|   | 
 * |   |  _____ _     ___ ____  ____  _  _____  |   | 
 * |   | |  ___| |   |_ _|  _ \/ ___|| |/ /_ _| |   | 
 * |   | | |_  | |    | || |_) \___ \| ' / | |  |   | 
 * |   | |  _| | |___ | ||  __/ ___) | . \ | |  |   | 
 * |   | |_|   |_____|___|_|   |____/|_|\_\___| |   | 
 * |___|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|___| 
 *(_____)                                      (_____)
 *
 */

contract FlipSkiV2 is AccessControl, ReentrancyGuard, Pausable, VRFConsumerBaseV2Plus {
    // Role defs
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant VRF_MANAGER_ROLE = keccak256("VRF_MANAGER_ROLE");

    // Constants
    address public constant ETH_ADDRESS = address(0);
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // 10%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_PENDING_GAMES = 5;
    uint256 public constant EMERGENCY_TIMEOUT = 1 hours;

    // VRF Configuration
    uint256 private vrfSubscriptionId;
    bytes32 private vrfKeyHash;
    uint32 private vrfCallbackGasLimit = 100000;
    uint16 private vrfRequestConfirmations = 3;
    uint32 private constant NUM_WORDS = 1;

    // Game config
    uint256 public feePercentage; // (1000 = 10%)
    address payable public feeWallet;
    uint256 public gameIdCounter;

    // Statistics tracking
    struct ContractStats {
        uint256 totalGamesPlayed;
        uint256 totalVolumeETH;
        uint256 totalFeesCollected;
        uint256 totalPlayersServed;
        mapping(address => uint256) tokenVolumes;
        mapping(address => uint256) tokenGamesCount;
    }
    
    ContractStats public stats;
    mapping(address => bool) public hasPlayedBefore;

    // Token configuration
    struct TokenConfig {
        address tokenAddress;
        string symbol;
        string name;
        uint8 decimals;
        uint256 minWager;
        uint256 maxWager;
        bool isActive;
        bool isPaused;
        uint256 addedTimestamp;
        address addedBy;
    }

    // Game data
    struct Game {
        address player;
        uint8 choice; // 0 = Heads (Flip), 1 = Tails (Ski)
        address tokenAddress;
        uint256 wagerAmount;
        uint256 feeAmount;
        uint256 payoutAmount;
        uint8 result; // 0 = Heads (Flip), 1 = Tails (Ski)
        bool requested;
        bool settled;
        uint256 vrfRequestId;
        uint256 requestTimestamp;
    }

    // Storage
    mapping(address => TokenConfig) public tokenConfigs;
    address[] public activeTokens;
    mapping(uint256 => Game) public games;
    mapping(uint256 => uint256) private vrfRequestToGameId;
    mapping(address => uint256) public pendingGamesCount;

    // Events
    event TokenAdded(
        address indexed tokenAddress,
        string symbol,
        string name,
        uint256 minWager,
        uint256 maxWager,
        address indexed addedBy
    );

    event TokenRemoved(
        address indexed tokenAddress,
        address indexed removedBy
    );

    event TokenConfigUpdated(
        address indexed tokenAddress,
        uint256 minWager,
        uint256 maxWager,
        address indexed updatedBy
    );

    event TokenPausedStatusChanged(
        address indexed tokenAddress,
        bool isPaused,
        address indexed changedBy
    );

    event GameRequested(
        uint256 indexed gameId,
        address indexed player,
        address indexed tokenAddress,
        uint8 choice,
        uint256 wagerAmount,
        uint256 vrfRequestId
    );

    event GameSettled(
        uint256 indexed gameId,
        address indexed player,
        address indexed tokenAddress,
        uint8 result,
        uint256 payoutAmount,
        uint256 feeAmount,
        uint256 vrfRequestId,
        bool playerWon
    );

    event EmergencyRefund(
        uint256 indexed gameId,
        address indexed player,
        address indexed tokenAddress,
        uint256 refundAmount
    );

    event FeeConfigUpdated(
        uint256 newFeePercentage,
        address newFeeWallet,
        address indexed updatedBy
    );

    event ContractFunded(
        address indexed tokenAddress,
        uint256 amount,
        address indexed funder
    );

    event EmergencyWithdrawal(
        address indexed tokenAddress,
        uint256 amount,
        address indexed withdrawnBy
    );

    // NEW: VRF Configuration Events
    event VRFConfigUpdated(
        address indexed vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        address indexed updatedBy
    );

    event VRFCoordinatorUpdated(
        address oldCoordinator,
        address newCoordinator,
        address indexed updatedBy
    );

    /**
     * @dev Constructor
     */
    constructor(
        address payable _initialFeeWallet,
        uint256 _initialFeePercentage,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _initialAdmin
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_initialFeeWallet != address(0), "Invalid fee wallet");
        require(_initialFeePercentage <= MAX_FEE_PERCENTAGE, "Fee too high");
        require(_initialAdmin != address(0), "Invalid admin address");

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(TOKEN_MANAGER_ROLE, _initialAdmin);
        _grantRole(OPERATOR_ROLE, _initialAdmin);
        _grantRole(VRF_MANAGER_ROLE, _initialAdmin); // NEW: VRF management role

        // Initialize configuration
        feeWallet = _initialFeeWallet;
        feePercentage = _initialFeePercentage;
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;

        // Add ETH as default token
        _addToken(
            ETH_ADDRESS,
            "ETH",
            "Ethereum",
            18,
            0.001 ether, // 0.001 ETH min
            10 ether,    // 10 ETH max
            msg.sender
        );
    }

    // ============ MODIFIERS ============

    modifier validToken(address tokenAddress) {
        require(tokenConfigs[tokenAddress].isActive, "Token not active");
        require(!tokenConfigs[tokenAddress].isPaused, "Token paused");
        _;
    }

    modifier validWager(address tokenAddress, uint256 amount) {
        TokenConfig memory config = tokenConfigs[tokenAddress];
        require(amount >= config.minWager, "Wager below minimum");
        require(amount <= config.maxWager, "Wager above maximum");
        _;
    }

    // ============ NEW: VRF MANAGEMENT FUNCTIONS ============

    /**
     * @dev Update VRF Coordinator address
     * @param newCoordinator New VRF Coordinator address
     */
    function updateVRFCoordinator(address newCoordinator) external onlyRole(VRF_MANAGER_ROLE) {
        require(newCoordinator != address(0), "Invalid coordinator address");
        
        address oldCoordinator = address(s_vrfCoordinator);
        s_vrfCoordinator = IVRFCoordinatorV2Plus(newCoordinator);
        
        emit VRFCoordinatorUpdated(oldCoordinator, newCoordinator, msg.sender);
    }

    /**
     * @dev Update VRF subscription ID
     * @param newSubscriptionId New subscription ID
     */
    function updateVRFSubscriptionId(uint256 newSubscriptionId) external onlyRole(VRF_MANAGER_ROLE) {
        require(newSubscriptionId > 0, "Invalid subscription ID");
        
        vrfSubscriptionId = newSubscriptionId;
        
        emit VRFConfigUpdated(
            address(s_vrfCoordinator),
            newSubscriptionId,
            vrfKeyHash,
            vrfCallbackGasLimit,
            vrfRequestConfirmations,
            msg.sender
        );
    }

    /**
     * @dev Update VRF key hash
     * @param newKeyHash New key hash for gas lane
     */
    function updateVRFKeyHash(bytes32 newKeyHash) external onlyRole(VRF_MANAGER_ROLE) {
        require(newKeyHash != bytes32(0), "Invalid key hash");
        
        vrfKeyHash = newKeyHash;
        
        emit VRFConfigUpdated(
            address(s_vrfCoordinator),
            vrfSubscriptionId,
            newKeyHash,
            vrfCallbackGasLimit,
            vrfRequestConfirmations,
            msg.sender
        );
    }

    /**
     * @dev Update VRF callback gas limit
     * @param newGasLimit New gas limit for VRF callback
     */
    function updateVRFGasLimit(uint32 newGasLimit) external onlyRole(VRF_MANAGER_ROLE) {
        require(newGasLimit >= 50000 && newGasLimit <= 2500000, "Gas limit out of range");
        
        vrfCallbackGasLimit = newGasLimit;
        
        emit VRFConfigUpdated(
            address(s_vrfCoordinator),
            vrfSubscriptionId,
            vrfKeyHash,
            newGasLimit,
            vrfRequestConfirmations,
            msg.sender
        );
    }

    /**
     * @dev Update VRF request confirmations
     * @param newConfirmations New number of confirmations
     */
    function updateVRFConfirmations(uint16 newConfirmations) external onlyRole(VRF_MANAGER_ROLE) {
        require(newConfirmations >= 1 && newConfirmations <= 200, "Confirmations out of range");
        
        vrfRequestConfirmations = newConfirmations;
        
        emit VRFConfigUpdated(
            address(s_vrfCoordinator),
            vrfSubscriptionId,
            vrfKeyHash,
            vrfCallbackGasLimit,
            newConfirmations,
            msg.sender
        );
    }

    /**
     * @dev Update all VRF settings at once
     */
    function updateVRFConfig(
        address newCoordinator,
        uint256 newSubscriptionId,
        bytes32 newKeyHash,
        uint32 newGasLimit,
        uint16 newConfirmations
    ) external onlyRole(VRF_MANAGER_ROLE) {
        require(newCoordinator != address(0), "Invalid coordinator");
        require(newSubscriptionId > 0, "Invalid subscription ID");
        require(newKeyHash != bytes32(0), "Invalid key hash");
        require(newGasLimit >= 50000 && newGasLimit <= 2500000, "Gas limit out of range");
        require(newConfirmations >= 1 && newConfirmations <= 200, "Confirmations out of range");

        // Update coordinator if changed
        if (newCoordinator != address(s_vrfCoordinator)) {
            address oldCoordinator = address(s_vrfCoordinator);
            s_vrfCoordinator = IVRFCoordinatorV2Plus(newCoordinator);
            emit VRFCoordinatorUpdated(oldCoordinator, newCoordinator, msg.sender);
        }

        // Update other settings
        vrfSubscriptionId = newSubscriptionId;
        vrfKeyHash = newKeyHash;
        vrfCallbackGasLimit = newGasLimit;
        vrfRequestConfirmations = newConfirmations;

        emit VRFConfigUpdated(
            newCoordinator,
            newSubscriptionId,
            newKeyHash,
            newGasLimit,
            newConfirmations,
            msg.sender
        );
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Add a new token for wagering
     */
    function addToken(
        address tokenAddress,
        uint256 minWager,
        uint256 maxWager
    ) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(tokenAddress != address(0), "Invalid token address");
        require(!tokenConfigs[tokenAddress].isActive, "Token already exists");
        require(minWager > 0, "Min wager must be > 0");
        require(maxWager > minWager, "Max wager must be > min wager");

        string memory symbol;
        string memory name;
        uint8 decimals;

        if (tokenAddress == ETH_ADDRESS) {
            symbol = "ETH";
            name = "Ethereum";
            decimals = 18;
        } else {
            // Get token metadata
            IERC20Metadata token = IERC20Metadata(tokenAddress);
            symbol = token.symbol();
            name = token.name();
            decimals = token.decimals();
        }

        _addToken(tokenAddress, symbol, name, decimals, minWager, maxWager, msg.sender);
    }

    /**
     * @dev Remove a token from wagering (soft delete)
     */
    function removeToken(address tokenAddress) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(tokenConfigs[tokenAddress].isActive, "Token not active");
        require(tokenAddress != ETH_ADDRESS, "Cannot remove ETH");

        tokenConfigs[tokenAddress].isActive = false;
        
        // Remove from active tokens array
        for (uint256 i = 0; i < activeTokens.length; i++) {
            if (activeTokens[i] == tokenAddress) {
                activeTokens[i] = activeTokens[activeTokens.length - 1];
                activeTokens.pop();
                break;
            }
        }

        emit TokenRemoved(tokenAddress, msg.sender);
    }

    /**
     * @dev Update token configuration
     */
    function updateTokenConfig(
        address tokenAddress,
        uint256 minWager,
        uint256 maxWager
    ) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(tokenConfigs[tokenAddress].isActive, "Token not active");
        require(minWager > 0, "Min wager must be > 0");
        require(maxWager > minWager, "Max wager must be > min wager");

        tokenConfigs[tokenAddress].minWager = minWager;
        tokenConfigs[tokenAddress].maxWager = maxWager;

        emit TokenConfigUpdated(tokenAddress, minWager, maxWager, msg.sender);
    }

    /**
     * @dev Pause or unpause a token
     */
    function setTokenPaused(address tokenAddress, bool isPaused) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(tokenConfigs[tokenAddress].isActive, "Token not active");
        
        tokenConfigs[tokenAddress].isPaused = isPaused;
        
        emit TokenPausedStatusChanged(tokenAddress, isPaused, msg.sender);
    }

    /**
     * @dev Update fee configuration
     */
    function updateFeeConfig(
        uint256 newFeePercentage,
        address payable newFeeWallet
    ) external onlyRole(ADMIN_ROLE) {
        require(newFeePercentage <= MAX_FEE_PERCENTAGE, "Fee too high");
        require(newFeeWallet != address(0), "Invalid fee wallet");

        feePercentage = newFeePercentage;
        feeWallet = newFeeWallet;

        emit FeeConfigUpdated(newFeePercentage, newFeeWallet, msg.sender);
    }

    /**
     * @dev Pause the entire contract
     */
    function pauseContract() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the entire contract
     */
    function unpauseContract() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Emergency withdrawal function
     */
    function emergencyWithdraw(address tokenAddress, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (tokenAddress == ETH_ADDRESS) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            feeWallet.transfer(amount);
        } else {
            IERC20 token = IERC20(tokenAddress);
            require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
            require(token.transfer(feeWallet, amount), "Token transfer failed");
        }

        emit EmergencyWithdrawal(tokenAddress, amount, msg.sender);
    }

    // ============ GAME FUNCTIONS ============

    /**
     * @dev Main function to flip coin
     */
    function flipski(
        uint8 choice,
        address tokenAddress,
        uint256 wagerAmount
    ) external payable nonReentrant whenNotPaused validToken(tokenAddress) validWager(tokenAddress, wagerAmount) {
        require(choice <= 1, "Invalid choice");
        require(pendingGamesCount[msg.sender] < MAX_PENDING_GAMES, "Too many pending games");

        uint256 gameId = ++gameIdCounter;
        uint256 feeAmount = (wagerAmount * feePercentage) / BASIS_POINTS;
        uint256 payoutAmount = (wagerAmount * 2) - feeAmount;

        // Handle wager collection
        if (tokenAddress == ETH_ADDRESS) {
            require(msg.value == wagerAmount, "Incorrect ETH amount");
            require(address(this).balance >= payoutAmount, "Insufficient contract ETH balance");
        } else {
            require(msg.value == 0, "No ETH should be sent for token games");
            IERC20 token = IERC20(tokenAddress);
            require(token.balanceOf(address(this)) >= payoutAmount, "Insufficient contract token balance");
            require(token.transferFrom(msg.sender, address(this), wagerAmount), "Token transfer failed");
        }

        // Request randomness from VRF
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        // Store game data
        games[gameId] = Game({
            player: msg.sender,
            choice: choice,
            tokenAddress: tokenAddress,
            wagerAmount: wagerAmount,
            feeAmount: feeAmount,
            payoutAmount: payoutAmount,
            result: 0,
            requested: true,
            settled: false,
            vrfRequestId: requestId,
            requestTimestamp: block.timestamp
        });

        vrfRequestToGameId[requestId] = gameId;
        pendingGamesCount[msg.sender]++;

        // Update statistics
        _updateStats(msg.sender, tokenAddress, wagerAmount);

        emit GameRequested(gameId, msg.sender, tokenAddress, choice, wagerAmount, requestId);
    }

    /**
     * @dev Callback function used by VRF Coordinator
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 gameId = vrfRequestToGameId[requestId];
        Game storage game = games[gameId];
        
        require(game.requested && !game.settled, "Invalid game state");

        // Determine result (0 = Heads, 1 = Tails)
        uint8 result = uint8(randomWords[0] % 2);
        game.result = result;
        game.settled = true;

        bool playerWon = (game.choice == result);
        pendingGamesCount[game.player]--;

        if (playerWon) {
            // Player wins - send payout
            if (game.tokenAddress == ETH_ADDRESS) {
                payable(game.player).transfer(game.payoutAmount);
                if (game.feeAmount > 0) {
                    feeWallet.transfer(game.feeAmount);
                }
            } else {
                IERC20 token = IERC20(game.tokenAddress);
                require(token.transfer(game.player, game.payoutAmount), "Payout transfer failed");
                if (game.feeAmount > 0) {
                    require(token.transfer(feeWallet, game.feeAmount), "Fee transfer failed");
                }
            }
        } else {
            // Player loses - send fee to fee wallet, keep rest in contract
            if (game.tokenAddress == ETH_ADDRESS) {
                if (game.feeAmount > 0) {
                    feeWallet.transfer(game.feeAmount);
                }
            } else {
                if (game.feeAmount > 0) {
                    IERC20 token = IERC20(game.tokenAddress);
                    require(token.transfer(feeWallet, game.feeAmount), "Fee transfer failed");
                }
            }
        }

        // Update fee collection stats
        stats.totalFeesCollected += game.feeAmount;

        emit GameSettled(
            gameId,
            game.player,
            game.tokenAddress,
            result,
            playerWon ? game.payoutAmount : 0,
            game.feeAmount,
            requestId,
            playerWon
        );
    }

    /**
     * @dev Emergency refund for stuck games
     */
    function emergencyRefund(uint256 gameId) external nonReentrant {
        Game storage game = games[gameId];
        require(game.player == msg.sender, "Not your game");
        require(game.requested && !game.settled, "Game not eligible for refund");
        require(block.timestamp >= game.requestTimestamp + EMERGENCY_TIMEOUT, "Timeout not reached");

        game.settled = true;
        pendingGamesCount[game.player]--;

        // Refund the wager amount
        if (game.tokenAddress == ETH_ADDRESS) {
            payable(game.player).transfer(game.wagerAmount);
        } else {
            IERC20 token = IERC20(game.tokenAddress);
            require(token.transfer(game.player, game.wagerAmount), "Refund transfer failed");
        }

        emit EmergencyRefund(gameId, game.player, game.tokenAddress, game.wagerAmount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get active tokens and their configurations
     */
    function getActiveTokens() external view returns (address[] memory, TokenConfig[] memory) {
        TokenConfig[] memory configs = new TokenConfig[](activeTokens.length);
        
        for (uint256 i = 0; i < activeTokens.length; i++) {
            configs[i] = tokenConfigs[activeTokens[i]];
        }
        
        return (activeTokens, configs);
    }

    /**
     * @dev Get game information
     */
    function getGame(uint256 gameId) external view returns (Game memory) {
        return games[gameId];
    }

    /**
     * @dev Get pending games count for a player
     */
    function getPendingGamesCount(address player) external view returns (uint256) {
        return pendingGamesCount[player];
    }

    /**
     * @dev Get contract balance for a token
     */
    function getContractBalance(address tokenAddress) external view returns (uint256) {
        if (tokenAddress == ETH_ADDRESS) {
            return address(this).balance;
        } else {
            return IERC20(tokenAddress).balanceOf(address(this));
        }
    }

    /**
     * @dev Get token configuration
     */
    function getTokenConfig(address tokenAddress) external view returns (TokenConfig memory) {
        return tokenConfigs[tokenAddress];
    }

    /**
     * @dev Check if token is supported
     */
    function isTokenSupported(address tokenAddress) external view returns (bool) {
        return tokenConfigs[tokenAddress].isActive && !tokenConfigs[tokenAddress].isPaused;
    }

    // ============ NEW: VRF VIEW FUNCTIONS ============

    /**
     * @dev Get current VRF configuration
     */
    function getVRFConfig() external view returns (
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations
    ) {
        return (
            address(s_vrfCoordinator),
            vrfSubscriptionId,
            vrfKeyHash,
            vrfCallbackGasLimit,
            vrfRequestConfirmations
        );
    }

    // ============ NEW: STATISTICS FUNCTIONS ============

    /**
     * @dev Get contract statistics
     */
    function getContractStats() external view returns (
        uint256 totalGamesPlayed,
        uint256 totalVolumeETH,
        uint256 totalFeesCollected,
        uint256 totalPlayersServed
    ) {
        return (
            stats.totalGamesPlayed,
            stats.totalVolumeETH,
            stats.totalFeesCollected,
            stats.totalPlayersServed
        );
    }

    /**
     * @dev Get token-specific statistics
     */
    function getTokenStats(address tokenAddress) external view returns (
        uint256 volume,
        uint256 gamesCount
    ) {
        return (
            stats.tokenVolumes[tokenAddress],
            stats.tokenGamesCount[tokenAddress]
        );
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Internal function to add a token
     */
    function _addToken(
        address tokenAddress,
        string memory symbol,
        string memory name,
        uint8 decimals,
        uint256 minWager,
        uint256 maxWager,
        address addedBy
    ) internal {
        tokenConfigs[tokenAddress] = TokenConfig({
            tokenAddress: tokenAddress,
            symbol: symbol,
            name: name,
            decimals: decimals,
            minWager: minWager,
            maxWager: maxWager,
            isActive: true,
            isPaused: false,
            addedTimestamp: block.timestamp,
            addedBy: addedBy
        });

        activeTokens.push(tokenAddress);

        emit TokenAdded(tokenAddress, symbol, name, minWager, maxWager, addedBy);
    }

    /**
     * @dev Update statistics
     */
    function _updateStats(address player, address tokenAddress, uint256 wagerAmount) internal {
        stats.totalGamesPlayed++;
        
        if (tokenAddress == ETH_ADDRESS) {
            stats.totalVolumeETH += wagerAmount;
        }
        
        stats.tokenVolumes[tokenAddress] += wagerAmount;
        stats.tokenGamesCount[tokenAddress]++;
        
        if (!hasPlayedBefore[player]) {
            hasPlayedBefore[player] = true;
            stats.totalPlayersServed++;
        }
    }

    // ============ FUNDING FUNCTIONS ============

    /**
     * @dev Fund contract with ETH
     */
    receive() external payable {
        emit ContractFunded(ETH_ADDRESS, msg.value, msg.sender);
    }

    /**
     * @dev Fund contract with tokens
     */
    function fundContract(address tokenAddress, uint256 amount) external {
        require(tokenAddress != ETH_ADDRESS, "Use receive() for ETH");
        require(tokenConfigs[tokenAddress].isActive, "Token not supported");
        
        IERC20 token = IERC20(tokenAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        
        emit ContractFunded(tokenAddress, amount, msg.sender);
    }
}

