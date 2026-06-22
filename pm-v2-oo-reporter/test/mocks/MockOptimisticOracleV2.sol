// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOptimisticOracleV2} from "src/interfaces/IOptimisticOracleV2.sol";
import {IOptimisticRequester} from "src/interfaces/IOptimisticRequester.sol";

contract MockOptimisticOracleV2 is IOptimisticOracleV2 {
    struct MockRequest {
        bool requested;
        bool eventBased;
        bool callbackOnPriceProposed;
        bool callbackOnPriceDisputed;
        bool callbackOnPriceSettled;
        bool settled;
        IERC20 currency;
        uint256 reward;
        uint256 bond;
        uint256 customLiveness;
        int256 price;
    }

    mapping(bytes32 requestKey => MockRequest request) public requests;
    mapping(IERC20 currency => mapping(address deferredRecipient => uint256 amount)) public deferredPayouts;
    uint256 public minimumDisputeWindow = 5 minutes;
    bool public deferNextDisputeRefund;

    function getMockRequest(bytes32 key) external view returns (MockRequest memory) {
        return requests[key];
    }

    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
        view
        returns (IOptimisticOracleV2.Request memory)
    {
        MockRequest storage request = requests[requestKey(requester, identifier, timestamp, requestRules)];

        IOptimisticOracleV2.RequestSettings memory requestSettings = IOptimisticOracleV2.RequestSettings({
            eventBased: request.eventBased,
            refundOnDispute: request.eventBased,
            callbackOnPriceProposed: request.callbackOnPriceProposed,
            callbackOnPriceDisputed: request.callbackOnPriceDisputed,
            callbackOnPriceSettled: request.callbackOnPriceSettled,
            bond: request.bond,
            customLiveness: request.customLiveness
        });

        return IOptimisticOracleV2.Request({
            proposer: address(0),
            disputer: address(0),
            currency: request.currency,
            settled: request.settled,
            requestSettings: requestSettings,
            proposedPrice: 0,
            resolvedPrice: request.price,
            expirationTime: 0,
            reward: request.reward,
            finalFee: 0,
            proposalTime: 0
        });
    }

    function requestKey(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(requester, identifier, timestamp, requestRules));
    }

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        IERC20 currency,
        uint256 reward
    ) external returns (uint256 totalBond) {
        bytes32 key = requestKey(msg.sender, identifier, timestamp, requestRules);
        MockRequest storage request = requests[key];
        require(!request.requested, "already requested");

        request.requested = true;
        request.currency = currency;
        request.reward = reward;

        if (reward > 0) {
            require(currency.transferFrom(msg.sender, address(this), reward), "reward transfer failed");
        }

        return request.bond;
    }

    function setEventBased(bytes32 identifier, uint256 timestamp, bytes memory requestRules) external {
        requests[requestKey(msg.sender, identifier, timestamp, requestRules)].eventBased = true;
    }

    function setCallbacks(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory requestRules,
        bool callbackOnPriceProposed,
        bool callbackOnPriceDisputed,
        bool callbackOnPriceSettled
    ) external {
        MockRequest storage request = requests[requestKey(msg.sender, identifier, timestamp, requestRules)];
        request.callbackOnPriceProposed = callbackOnPriceProposed;
        request.callbackOnPriceDisputed = callbackOnPriceDisputed;
        request.callbackOnPriceSettled = callbackOnPriceSettled;
    }

    function setBond(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 bond)
        external
        returns (uint256 totalBond)
    {
        requests[requestKey(msg.sender, identifier, timestamp, requestRules)].bond = bond;
        return bond;
    }

    function setCustomLiveness(bytes32 identifier, uint256 timestamp, bytes memory requestRules, uint256 customLiveness)
        external
    {
        require(customLiveness >= minimumDisputeWindow, "liveness below minimum");
        require(customLiveness < 5200 weeks, "liveness too long");

        requests[requestKey(msg.sender, identifier, timestamp, requestRules)].customLiveness = customLiveness;
    }

    function disputePrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules)
        external
    {
        MockRequest storage request = requests[requestKey(requester, identifier, timestamp, requestRules)];
        require(request.requested, "not requested");

        uint256 refund = request.reward;
        if (refund > 0) {
            request.reward = 0;
            if (deferNextDisputeRefund) {
                deferNextDisputeRefund = false;
                deferredPayouts[request.currency][requester] += refund;
            } else {
                require(request.currency.transfer(requester, refund), "refund transfer failed");
            }
        }

        if (request.callbackOnPriceDisputed) {
            IOptimisticRequester(requester).priceDisputed(identifier, timestamp, requestRules, refund);
        }
    }

    function settle(address requester, bytes32 identifier, uint256 timestamp, bytes memory requestRules, int256 price)
        external
    {
        MockRequest storage request = requests[requestKey(requester, identifier, timestamp, requestRules)];
        require(request.requested, "not requested");

        request.settled = true;
        request.price = price;

        if (request.callbackOnPriceSettled) {
            IOptimisticRequester(requester).priceSettled(identifier, timestamp, requestRules, price);
        }
    }

    function claimDeferredPayout(IERC20 currency, address repaymentAddress) external {
        uint256 amount = deferredPayouts[currency][msg.sender];
        require(amount > 0, "no deferred payout");

        deferredPayouts[currency][msg.sender] = 0;
        require(currency.transfer(repaymentAddress, amount), "deferred payout transfer failed");
    }

    function setDeferredPayout(IERC20 currency, address deferredRecipient, uint256 amount) external {
        deferredPayouts[currency][deferredRecipient] = amount;
    }

    function setDeferNextDisputeRefund(bool defer) external {
        deferNextDisputeRefund = defer;
    }

    function setMinimumDisputeWindow(uint256 newMinimumDisputeWindow) external {
        minimumDisputeWindow = newMinimumDisputeWindow;
    }
}
