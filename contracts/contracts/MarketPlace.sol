// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract PredictionMarketplace is AccessControl {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MOD_ROLE = keccak256("MOD_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PREDICTOR_ROLE = keccak256("PREDICTOR_ROLE");

    // Enums
    enum PredictionType { BINARY, MULTIPLE_CHOICE, RANGE }
    enum PredictionStatus { ACTIVE, FINALIZED, CANCELLED }

    // Constants
    uint256 public constant VOTE_VALUE = 0.001 ether;

    // Structs
    struct Prediction {
        string description;
        uint256 endTime;
        PredictionStatus status;
        uint256[] totalVotes;
        mapping(address => uint256[]) userVotes;
        uint256 outcome;
        uint256 minVotes;
        uint256 maxVotes;
        PredictionType predictionType;
        address creator;
        uint256 creationTime;
        string[] tags;
        uint256 optionsCount;
        uint256 totalBetAmount;
    }

    struct UserStats {
        uint256 totalVotes;
        uint256 wonVotes;
        uint256 totalAmountBet;
        uint256 totalAmountWon;
        uint256 luck;
    }

    // State variables
    uint256 public predictionCounter;
    mapping(uint256 => Prediction) public predictions;
    mapping(address => UserStats) public userStats;
    mapping(string => bool) public validTags;
    mapping(uint256 => mapping(address => bool)) public userParticipation;

    uint256 public constant FEE_PERCENTAGE = 25; // 2.5% fee (25/1000)
    uint256 public totalFees;
    uint256 public constant MAX_OPTIONS = 10; // Maximum number of options for multiple choice predictions

    address[] public luckiestUsers;

    // Events
    event PredictionCreated(uint256 indexed predictionId, address indexed creator, string description, uint256 endTime, PredictionType predictionType);
    event VotesPlaced(uint256 indexed predictionId, address indexed user, uint256 option, uint256 votes);
    event PredictionFinalized(uint256 indexed predictionId, uint256 outcome);
    event RewardsDistributed(uint256 indexed predictionId, address[] winners, uint256[] amounts);
    event PredictionCancelled(uint256 indexed predictionId);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event PartialWithdrawal(uint256 indexed predictionId, address indexed user, uint256 votes);
    event TagAdded(string tag);
    event TagRemoved(string tag);
    event LuckUpdated(address indexed user, uint256 newLuck);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PREDICTOR_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // Modifiers
    modifier onlyValidPrediction(uint256 _predictionId) {
        require(predictions[_predictionId].status == PredictionStatus.ACTIVE, "Prediction is not active");
        require(block.timestamp < predictions[_predictionId].endTime, "Prediction has ended");
        _;
    }

    // Functions
    function createPrediction(
        string memory _description,
        uint256 _duration,
        uint256 _minVotes,
        uint256 _maxVotes,
        PredictionType _type,
        uint256 _optionsCount,
        string[] memory _tags
    ) external onlyRole(PREDICTOR_ROLE) {
        require(_optionsCount >= 2 && _optionsCount <= MAX_OPTIONS, "Invalid number of options");
        require(_minVotes > 0 && _maxVotes >= _minVotes, "Invalid vote limits");
        
        uint256 predictionId = predictionCounter++;

        Prediction storage newPrediction = predictions[predictionId];
        newPrediction.description = _description;
        newPrediction.endTime = block.timestamp + _duration;
        newPrediction.status = PredictionStatus.ACTIVE;
        newPrediction.minVotes = _minVotes;
        newPrediction.maxVotes = _maxVotes;
        newPrediction.predictionType = _type;
        newPrediction.creator = msg.sender;
        newPrediction.creationTime = block.timestamp;
        newPrediction.optionsCount = _optionsCount;

        for (uint256 i = 0; i < _optionsCount; i++) {
            newPrediction.totalVotes.push(0);
        }

        for (uint256 i = 0; i < _tags.length; i++) {
            newPrediction.tags.push(_tags[i]);
        }

        emit PredictionCreated(predictionId, msg.sender, _description, newPrediction.endTime, _type);
    }

    function placeVotes(uint256 _predictionId, uint256 _option, uint256 _votes) external payable onlyValidPrediction(_predictionId) {
        Prediction storage prediction = predictions[_predictionId];
        require(_option < prediction.optionsCount, "Invalid option");
        require(_votes >= prediction.minVotes && _votes <= prediction.maxVotes, "Votes out of range");
        require(msg.value == _votes * VOTE_VALUE, "Incorrect ETH amount");

        prediction.totalVotes[_option] += _votes;
        prediction.userVotes[msg.sender].push(_votes);
        prediction.totalBetAmount += msg.value;

        userStats[msg.sender].totalVotes += _votes;
        userStats[msg.sender].totalAmountBet += msg.value;
        userParticipation[_predictionId][msg.sender] = true;

        updateLuckiestUsers(msg.sender);

        emit VotesPlaced(_predictionId, msg.sender, _option, _votes);
    }

    function partialWithdraw(uint256 _predictionId, uint256 _votes) external onlyValidPrediction(_predictionId) {
        Prediction storage prediction = predictions[_predictionId];
        uint256 userTotalVotes = 0;
        for (uint256 i = 0; i < prediction.userVotes[msg.sender].length; i++) {
            userTotalVotes += prediction.userVotes[msg.sender][i];
        }
        require(_votes <= userTotalVotes, "Withdrawal votes exceed bet");

        uint256 penalty = (_votes * 10) / 100; // 10% penalty
        uint256 withdrawalVotes = _votes - penalty;
        uint256 withdrawalAmount = withdrawalVotes * VOTE_VALUE;

        // Update user's votes and total votes
        uint256 remainingWithdrawal = _votes;
        for (uint256 i = 0; i < prediction.optionsCount; i++) {
            if (remainingWithdrawal == 0) break;
            if (prediction.userVotes[msg.sender][i] > 0) {
                uint256 withdrawFromOption = remainingWithdrawal > prediction.userVotes[msg.sender][i] ?
                    prediction.userVotes[msg.sender][i] : remainingWithdrawal;
                prediction.userVotes[msg.sender][i] -= withdrawFromOption;
                prediction.totalVotes[i] -= withdrawFromOption;
                remainingWithdrawal -= withdrawFromOption;
            }
        }

        prediction.totalBetAmount -= withdrawalAmount + (penalty * VOTE_VALUE);
        totalFees += penalty * VOTE_VALUE;
        payable(msg.sender).transfer(withdrawalAmount);

        emit PartialWithdrawal(_predictionId, msg.sender, withdrawalVotes);
    }

    function finalizePrediction(uint256 _predictionId, uint256 _outcome) external onlyRole(ORACLE_ROLE) {
        Prediction storage prediction = predictions[_predictionId];
        require(prediction.status == PredictionStatus.ACTIVE, "Prediction is not active");
        require(block.timestamp >= prediction.endTime, "Prediction has not ended yet");
        require(_outcome < prediction.optionsCount, "Invalid outcome");

        prediction.status = PredictionStatus.FINALIZED;
        prediction.outcome = _outcome;

        emit PredictionFinalized(_predictionId, _outcome);
    }

    function distributeRewards(uint256 _predictionId) external onlyRole(ADMIN_ROLE) {
        Prediction storage prediction = predictions[_predictionId];
        require(prediction.status == PredictionStatus.FINALIZED, "Prediction is not finalized");

        uint256 fee = (prediction.totalBetAmount * FEE_PERCENTAGE) / 1000;
        uint256 winningVotes = prediction.totalVotes[prediction.outcome];
        uint256 rewardPool = prediction.totalBetAmount - fee;

        totalFees += fee;

        address[] memory winners = new address[](predictionCounter);
        uint256[] memory amounts = new uint256[](predictionCounter);
        uint256 winnerCount = 0;

        for (uint256 i = 0; i < predictionCounter; i++) {
            address participant = address(uint160(i));
            if (userParticipation[_predictionId][participant]) {
                uint256 participantVotes = prediction.userVotes[participant][prediction.outcome];
                if (participantVotes > 0) {
                    uint256 reward = (participantVotes * rewardPool) / winningVotes;
                    payable(participant).transfer(reward);
                    userStats[participant].wonVotes += participantVotes;
                    userStats[participant].totalAmountWon += reward;
                    winners[winnerCount] = participant;
                    amounts[winnerCount] = reward;
                    winnerCount++;

                    updateLuck(participant, true);
                } else {
                    updateLuck(participant, false);
                }
            }
        }

        // Resize arrays to actual winner count
        assembly {
            mstore(winners, winnerCount)
            mstore(amounts, winnerCount)
        }

        emit RewardsDistributed(_predictionId, winners, amounts);
    }

    function updateLuck(address _user, bool _won) internal {
        UserStats storage stats = userStats[_user];
        if (_won) {
            stats.luck += 10;
        } else {
            if (stats.luck >= 5) {
                stats.luck -= 5;
            } else {
                stats.luck = 0;
            }
        }
        emit LuckUpdated(_user, stats.luck);
        updateLuckiestUsers(_user);
    }

    function updateLuckiestUsers(address _user) internal {
        uint256 userLuck = userStats[_user].luck;
        uint256 leaderboardLength = luckiestUsers.length;

        for (uint256 i = 0; i < leaderboardLength; i++) {
            if (luckiestUsers[i] == _user) {
                // User is already in leaderboard, remove them
                for (uint256 j = i; j < leaderboardLength - 1; j++) {
                    luckiestUsers[j] = luckiestUsers[j + 1];
                }
                luckiestUsers.pop();
                break;
            }
        }

        // Find the correct position to insert the user
        for (uint256 i = 0; i < luckiestUsers.length; i++) {
            if (userStats[luckiestUsers[i]].luck < userLuck) {
                luckiestUsers.push(address(0)); // Extend array
                for (uint256 j = luckiestUsers.length - 1; j > i; j--) {
                    luckiestUsers[j] = luckiestUsers[j - 1];
                }
                luckiestUsers[i] = _user;
                return;
            }
        }

        // If not inserted, add to the end
        luckiestUsers.push(_user);
    }

    function getLuckiestUsers(uint256 _limit) external view returns (address[] memory, uint256[] memory) {
        require(_limit > 0 && _limit <= luckiestUsers.length, "Invalid limit");
        address[] memory topUsers = new address[](_limit);
        uint256[] memory luckScores = new uint256[](_limit);

        for (uint256 i = 0; i < _limit; i++) {
            topUsers[i] = luckiestUsers[i];
            luckScores[i] = userStats[luckiestUsers[i]].luck;
        }

        return (topUsers, luckScores);
    }

    function cancelPrediction(uint256 _predictionId) external onlyRole(ADMIN_ROLE) {
        Prediction storage prediction = predictions[_predictionId];
        require(prediction.status == PredictionStatus.ACTIVE, "Prediction is not active");

        prediction.status = PredictionStatus.CANCELLED;

        // Refund all participants
        for (uint256 i = 0; i < predictionCounter; i++) {
            address participant = address(uint160(i));
            if (userParticipation[_predictionId][participant]) {
                uint256 totalRefund = 0;
                for (uint256 j = 0; j < prediction.optionsCount; j++) {
                    totalRefund += prediction.userVotes[participant][j];
                    prediction.userVotes[participant][j] = 0;
                }
                if (totalRefund > 0) {
                    payable(participant).transfer(totalRefund * VOTE_VALUE);
                }
            }
        }

        emit PredictionCancelled(_predictionId);
    }

    function withdrawFees(address payable _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_amount <= totalFees, "Insufficient fees collected");
        totalFees -= _amount;
        _to.transfer(_amount);
        emit FeeWithdrawn(_to, _amount);
    }

    function addValidTag(string memory _tag) external onlyRole(ADMIN_ROLE) {
        require(!validTags[_tag], "Tag already exists");
        validTags[_tag] = true;
        emit TagAdded(_tag);
    }

    function removeValidTag(string memory _tag) external onlyRole(ADMIN_ROLE) {
        require(validTags[_tag], "Tag does not exist");
        validTags[_tag] = false;
        emit TagRemoved(_tag);
    }

    function getUserStats(address _user) external view returns (UserStats memory) {
        return userStats[_user];
    }

   function getPredictionDetails(uint256 _predictionId) external view returns (
        string memory description,
        uint256 endTime,
        PredictionStatus status,
        uint256[] memory totalVotes,
        uint256 outcome,
        uint256 minVotes,
        uint256 maxVotes,
        PredictionType predictionType,
        address creator,
        uint256 creationTime,
        string[] memory tags,
        uint256 optionsCount,
        uint256 totalBetAmount
    ) {
        Prediction storage prediction = predictions[_predictionId];
        return (
            prediction.description,
            prediction.endTime,
            prediction.status,
            prediction.totalVotes,
            prediction.outcome,
            prediction.minVotes,
            prediction.maxVotes,
            prediction.predictionType,
            prediction.creator,
            prediction.creationTime,
            prediction.tags,
            prediction.optionsCount,
            prediction.totalBetAmount
        );
    }

    function getUserVotes(uint256 _predictionId, address _user) external view returns (uint256[] memory) {
        return predictions[_predictionId].userVotes[_user];
    }

    function hasUserParticipated(uint256 _predictionId, address _user) external view returns (bool) {
        return userParticipation[_predictionId][_user];
    }

    function calculatePotentialWinnings(uint256 _predictionId, uint256 _option, uint256 _votes) external view returns (uint256) {
        Prediction storage prediction = predictions[_predictionId];
        require(prediction.status == PredictionStatus.ACTIVE, "Prediction is not active");
        require(_option < prediction.optionsCount, "Invalid option");

        uint256 totalBetWithNewVotes = prediction.totalBetAmount + (_votes * VOTE_VALUE);
        uint256 fee = (totalBetWithNewVotes * FEE_PERCENTAGE) / 1000;
        uint256 rewardPool = totalBetWithNewVotes - fee;

        uint256 optionVotesWithNew = prediction.totalVotes[_option] + _votes;
        return ((_votes * rewardPool) / optionVotesWithNew);
    }

    // Role management functions
    function grantPredictorRole(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(PREDICTOR_ROLE, _account);
    }

    function revokePredictorRole(address _account) external onlyRole(ADMIN_ROLE) {
        revokeRole(PREDICTOR_ROLE, _account);
    }

    function grantModRole(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(MOD_ROLE, _account);
    }

    function revokeModRole(address _account) external onlyRole(ADMIN_ROLE) {
        revokeRole(MOD_ROLE, _account);
    }

    function grantOracleRole(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(ORACLE_ROLE, _account);
    }

    function revokeOracleRole(address _account) external onlyRole(ADMIN_ROLE) {
        revokeRole(ORACLE_ROLE, _account);
    }

    receive() external payable {}
}