pragma solidity ^0.8.0;

// SPDX-License-Identifier: MIT

import "./interfaces/IAaveFinancing.sol";
import "../core/DaoConstants.sol";
import "../core/DaoRegistry.sol";
import "../extensions/bank/Bank.sol";
import "../adapters/interfaces/IVoting.sol";
import "../guards/MemberGuard.sol";
import "../guards/AdapterGuard.sol";
import "../aave-interfaces/ILendingPoolAddressesProvider.sol";
import "../aave-interfaces/ILendingPool.sol";

/**
MIT License
Copyright (c) 2020 Openlaw
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
 */

contract AaveFinancing is
    IAaveFinancing,
    DaoConstants,
    MemberGuard,
    AdapterGuard
{

    ILendingPoolAddressesProvider lendingPoolAddressesProvider = ILendingPoolAddressesProvider(address(0));
    ILendingPool lendingPool = ILendingPool(lendingPoolAddressesProvider.getLendingPool());

    struct ProposalDetails {
        address applicant; // the proposal applicant address, can not be a reserved address
        uint256 amount; // the amount requested for funding
        address token; // the token address in which the funding must be sent to
        AaveDo watDo; // what to do on Aave
        address debtTokenRecipient;
    }

    // keeps track of all financing proposals handled by each dao
    mapping(address => mapping(bytes32 => ProposalDetails)) public proposals;

    /**
     * @notice default fallback function to prevent from sending ether to the contract.
     */
    receive() external payable {
        revert("fallback revert");
    }

    /**
     * @notice Creates and sponsors a financing proposal.
     * @dev Applicant address must not be reserved.
     * @dev Token address must be allowed/supported by the DAO Bank.
     * @dev Requested amount must be greater than zero.
     * @dev Only members of the DAO can sponsor a financing proposal.
     * @param dao The DAO Address.
     * @param proposalId The proposal id.
     * @param applicant The applicant address.
     * @param token The token to receive the funds.
     * @param amount The desired amount.
     * @param _watDo The aave action to carry out
     * @param data Additional details about the financing proposal.
     */
    function submitProposal(
        DaoRegistry dao,
        bytes32 proposalId,
        address applicant,
        address token,
        uint256 amount,
        AaveDo _watDo,
        bytes memory data
    ) external override reentrancyGuard(dao) {
        require(amount > 0, "invalid requested amount");
        BankExtension bank = BankExtension(dao.getExtensionAddress(BANK));
        require(bank.isTokenAllowed(token), "token not allowed");
        require(
            isNotReservedAddress(applicant),
            "applicant using reserved address"
        );
        dao.submitProposal(proposalId);

        ProposalDetails storage proposal = proposals[address(dao)][proposalId];
        proposal.applicant = applicant;
        proposal.amount = amount;
        proposal.token = token;
        proposal.watDo = _watDo;

        IVoting votingContract = IVoting(dao.getAdapterAddress(VOTING));
        address sponsoredBy =
            votingContract.getSenderAddress(
                dao,
                address(this),
                data,
                msg.sender
            );

        dao.sponsorProposal(proposalId, sponsoredBy, address(votingContract));
        votingContract.startNewVotingForProposal(dao, proposalId, data);
    }

    /**
     * @notice Processing a financing proposal to grant the requested funds.
     * @dev Only proposals that were not processed are accepted.
     * @dev Only proposals that were sponsored are accepted.
     * @dev Only proposals that passed can get processed and have the funds released.
     * @param dao The DAO Address.
     * @param proposalId The proposal id.
     */
    function processProposal(DaoRegistry dao, bytes32 proposalId)
        external
        override
        reentrancyGuard(dao)
    {
        ProposalDetails memory details = proposals[address(dao)][proposalId];

        IVoting votingContract = IVoting(dao.votingAdapter(proposalId));
        require(address(votingContract) != address(0), "adapter not found");

        require(
            votingContract.voteResult(dao, proposalId) ==
                IVoting.VotingState.PASS,
            "proposal needs to pass"
        );
        dao.processProposal(proposalId);
        BankExtension bank = BankExtension(dao.getExtensionAddress(BANK));

        if(details.watDo == AaveDo. Borrow){
            _executeAction(details.watDo, details.token, details.amount, address(this));
            IERC20(details.token).transferFrom(address(this), GUILD, details.amount);
        } else {
            bank.subtractFromBalance(GUILD, details.token, details.amount);
            bank.addToBalance(address(this), details.token, details.amount);

            require(bank.balanceOf(address(this), details.token) >= details.amount);

            bank.withdraw(payable(address(this)), details.token, details.amount);

            _executeAction(details.watDo, details.token, details.amount, address(bank));
        }
    }

    /**
     * @notice Execute actions on Aave protocol
     * @param _watDo Action to execute on Aave
     * @param _asset Token to interact with on Aave
     * @param _amount
     * @param _onBehalfOf 
     */
    function _executeAction(AaveDo _watDo, address _asset, uint256 _amount, address _onBehalfOf) internal {
        if (_watDo == AaveDo.Deposit) lendingPool.deposit(_asset, _amount, _onBehalfOf, 0);
        if (_watDo == AaveDo.Withdraw) lendingPool.withdraw(_asset, _amount, _onBehalfOf);
        if (_watDo == AaveDo.Borrow) lendingPool.borrow( _asset,_amount, 1, 0, _onBehalfOf);
        if (_watDo == AaveDo.Repay) lendingPool.repay(_asset, _amount, 1, _onBehalfOf);
    }
}