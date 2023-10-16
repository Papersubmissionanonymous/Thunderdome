/*
SPDX-License-Identifier: MIT
*/

pragma solidity >=0.5.16;
pragma experimental ABIEncoderV2;

library BrickBase {
    function divceil(uint a, uint m) 
    internal pure returns (uint) { 
        return (a + m - 1) / m;
    }
}

contract Brick {//the payment channel contract for Alice and Ingrid
    enum BrickPhase {// payment channel phases
        Deployed, AliceFunded, IngridFunded,
        Open, Cancelled, VcRegistered, Closed
    }
    
    struct ChannelState {//payment channel state between Alice and Ingrid
        uint256 aliceValue;
        uint256 channelValue;
        uint16 autoIncrement;//sequence number
    }

    struct VirtualChannelState {//virtual channel state between Alice and Bob
        uint256 aliceValue;
        uint256 VchannelValue;
        uint16 autoIncrement;
    }

    struct ECSignature {//the ecs signature
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
    struct Announcement {//payment channel state broacast to wardens
        uint16 autoIncrement;// no state broadcast?
        ECSignature aliceSig;// signature on the hashed sequece number
        ECSignature ingridSig;
    }

    struct VirtualAnnouncement {//virtual channel state broacast to wardens
        string Encstate;//encrypted state
        uint16 autoIncrement;//number
        ECSignature aliceSig;//A's sig
        ECSignature bobSig;//B's sig
        // ECSignature aliceSig2;//A's sig for sequence
        // ECSignature bobSig2;//B's sig for sequence
        ECSignature warden1Sig;
        ECSignature warden2Sig;
        ECSignature warden3Sig;
        ECSignature warden4Sig;
        ECSignature warden5Sig;
        ECSignature warden6Sig;
        ECSignature warden7Sig;
    }

    struct RegisterTransaction {//Registration transaction publish for the closing
        address Alice;
        address Bob;
        address Ingrid;//Three main parties
        uint256 VchannelValue;
        uint256 ValiceValue;
        ECSignature aliceSig;
        ECSignature ingridSig;
        ECSignature bobSig;
    }

    struct FraudProof {//proof-of-fraud
        Announcement statePoint;//announcement
        ECSignature watchtowerSig;//warden signature
        uint8 watchtowerIdx;//warden identity
    }

    struct VirtualFraudProof {//proof-of-fraud
        VirtualAnnouncement statePoint;//announcement
        // ECSignature watchtowerSig;//warden signature on sequence
        // ECSignature watchtowerSig2;//warden signature on value
        ECSignature watchtowerSig;//warden signature
        uint8 watchtowerIdx;//warden identity
    }

    mapping (uint16 => bool) announcementAutoIncrementSigned; //payment channel mapping
    mapping (uint16 => bool) VirtualannouncementStateSigned; //Virtual channel mapping


    uint256 public _initialAliceValue;//Alice initial money for payment channel
    uint256 public _initialIngridValue;//Ingrid initial money for payment channel
    uint256 public _virtualAliceValue;//Alice initial money for virtual channel
    uint256 public _virtualIngridValue;//Ingrid initial money for virtual channel
    uint256 public _initialChannelValue;//Initial channel value of payment channel
    uint256 public _ChannelValue;//Payment channel later
    uint256 public _VChannelClosedValue;//The sum of already closed virtual channel money
    uint8 public _n;//n
    uint8 public _t;//t
    uint256 constant public FEE = 20 wei; // must be even
    uint8 public _f;//f
    address payable public _alice;// alice address
    address payable public _ingrid;//ingrid address
    address payable public _bob;
    address payable[] public _watchtowers;//warden address
    BrickPhase public _phase;// payment channel phase
    bool[] public _watchtowerFunded;// warden fund or not
    uint256 public _collateral;//warden collateral
    bool public _ingridFunded;//ingrid fund
    bool _aliceRecovered;//recover
    bool _ingridRecovered;//recover

    uint16[] _watchtowerLastAutoIncrement;
    uint16[] _watchtowerLastAutoIncrementVirtual;
    string[] _watchtowerLastValueVirtual;
    Announcement _bestAnnouncementPayment;
    VirtualAnnouncement _bestAnnouncementVirtual;
    // bool[] _watchtowerClaimedClose;
    bool[] _watchtowerClaimedVirtualClose;
    bool[] _watchtowerClaimedPaymentClose;
    uint8 _numWatchtowerPaymentClaims;
    uint8 _numWatchtowerVirtualClaims;
    uint16 _maxWatchtowerAutoIncrementPaymentClaim;
    uint16 _maxWatchtowerAutoIncrementVirtualClaim;
    bool _aliceWantsClose;
    uint256 _aliceClaimedClosingValue;
    uint8 _numHonestClosingWatchtowers;

    modifier atPhase(BrickPhase phase) {
        require(_phase == phase, 'Invalid phase');
        _;
    }

    modifier aliceOnly() {
        require(msg.sender == _alice, 'Only Alice is allowed to call that');
        _;
    }

    modifier ingridOnly() {
        require(msg.sender == _ingrid, 'Only Ingrid is allowed to call that');
        _;
    }

    modifier openOnly() {
        require(_phase == BrickPhase.Open, 'Channel is not open');
        _;
    }

    function aliceFund(address payable ingrid, address payable[] memory watchtowers)
    public payable atPhase(BrickPhase.Deployed) {

        _n = uint8(watchtowers.length);//load parameters
        _f = (_n - 1) / 3;
        _t = 2*_f + 1;

        _alice = payable(msg.sender);//Alice first fund
        _initialAliceValue = msg.value - FEE / 2;
        _ingrid = ingrid;
        _watchtowers = watchtowers;
        for (uint8 i = 0; i < _n; ++i) {
            _watchtowerFunded.push(false);//initialize warden states
            _watchtowerClaimedVirtualClose.push(false);
            _watchtowerClaimedPaymentClose.push(false);
            _watchtowerLastAutoIncrement.push(0);
            _watchtowerLastAutoIncrementVirtual.push(0);
            _watchtowerLastValueVirtual.push("0");
        }
        _phase = BrickPhase.AliceFunded;
    }

    function fundingrid() external payable atPhase(BrickPhase.AliceFunded) {
        //Ingrid fun
        require(msg.value >= FEE / 2, 'ingrid must pay at least the fee');
        _initialIngridValue = msg.value - FEE / 2;
        _ingridFunded = true;
        
        //calculate each warden collateral
        if (_f > 0) {
            _collateral = BrickBase.divceil(_initialAliceValue + _initialIngridValue, _f);
        }

        //change state
        _phase = BrickPhase.IngridFunded;

        //calculate the initial channel value
        _initialChannelValue = _initialAliceValue + _initialIngridValue;
    }

    function fundWatchtower(uint8 idx)
    external payable atPhase(BrickPhase.IngridFunded) {// watchtower fund the channel
        require(msg.value >= _collateral, 'Watchtower must pay at least the collateral');
        _watchtowerFunded[idx] = true;
    }
    

    // function withdrawBeforeOpen(uint8 idx) external {
    //     uint256 amount;

    //     require(_phase == BrickPhase.AliceFunded ||
    //             _phase == BrickPhase.IngridFunded ||
    //             _phase == BrickPhase.Cancelled,
    //             'Withdrawals are only allowed early');

    //     if (msg.sender == _alice) {
    //         require(!_aliceRecovered, 'Alice has already withdrawn');
    //         _aliceRecovered = true;
    //         amount = _initialAliceValue + FEE / 2;
    //     }
    //     else if (msg.sender == _ingrid) {
    //         require(_ingridFunded, 'ingrid has already withdrawn');
    //         _ingridFunded = false;
    //         amount = _initialIngridValue + FEE / 2;
    //     }
    //     else if (msg.sender == _watchtowers[idx]) {
    //         require(_watchtowerFunded[idx], 'This watchtower has already withdrawn');
    //         _watchtowerFunded[idx] = false;
    //         amount = _collateral;
    //     }
    //     else {
    //         revert('Only the participants can withdraw');
    //     }

    //     _phase = BrickPhase.Cancelled;
    //     payable(msg.sender).transfer(amount);
    // }

    function open() external atPhase(BrickPhase.IngridFunded) {//open the payment channel
        
        for (uint8 idx = 0; idx < _n; ++idx) {
            require(_watchtowerFunded[idx], 'All watchtowers must fund the channel before opening it');
        }

        //change the state
        _phase = BrickPhase.Open;
    }

    function optimisticAliceClose(uint256 closingAliceValue)
    public openOnly aliceOnly {//optimistic closing
        
        //no extra money is giving
        require(closingAliceValue <=
                _initialAliceValue + _initialIngridValue, 'Channel cannot close at a higher value than it began at');
        
        // Ensure Alice doesn't later change her mind about the value
        // in a malicious attempt to frontrun ingrid's optimisticingridClose()
        require(!_aliceWantsClose, 'Alice can only decide to close with one state');
        _aliceWantsClose = true;
        _aliceClaimedClosingValue = closingAliceValue;
    }

    function optimisticIngridClose()
    public openOnly ingridOnly {//optimisitic closing finished by Ingrid
        require(_aliceWantsClose, 'ingrid cannot close on his own volition');

        //change the state and tranfer the money
        _phase = BrickPhase.Closed;
        _alice.transfer(_aliceClaimedClosingValue + FEE / 2);
        _ingrid.transfer(_initialChannelValue - _aliceClaimedClosingValue + FEE / 2);

        //wardens get back collateral
        for (uint256 idx = 0; idx < _n; ++idx) {
            _watchtowers[idx].transfer(_collateral);
        }
    }

    function virtualchannelregister(RegisterTransaction memory txr)
    public openOnly{
        _bob = payable(txr.Bob);
    }

    function watchtowerClaimState(Announcement memory announcement, uint256 idx)
    public openOnly {//watchtower publish payment channel information to the blockchain
        
        //Verify the announcement first
        require(validAnnouncement(announcement), 'Announcement does not have valid signatures by Alice and ingrid');
        require(msg.sender == _watchtowers[idx], 'This is not the watchtower claimed');
        require(!_watchtowerClaimedPaymentClose[idx], 'Each watchtower can only submit one pessimistic state');
        require(_numWatchtowerPaymentClaims < _t, 'Watchtower race is complete');

        //record the annoucement published by wardens
        _watchtowerLastAutoIncrement[idx] = announcement.autoIncrement;
        _watchtowerClaimedPaymentClose[idx] = true;
        ++_numWatchtowerPaymentClaims;

        if (announcement.autoIncrement > _maxWatchtowerAutoIncrementPaymentClaim) {
            _maxWatchtowerAutoIncrementPaymentClaim = announcement.autoIncrement;
            _bestAnnouncementPayment = announcement;
        }
    }

    function VirtualwatchtowerClaimState(VirtualAnnouncement memory announcement, uint256 idx)
    public openOnly {

        // verify the announcement first
        require(validVirtualAnnouncement(announcement), 'Announcement does not have valid signatures by Alice and Bob');
        require(msg.sender == _watchtowers[idx], 'This is not the watchtower claimed');
        require(!_watchtowerClaimedVirtualClose[idx], 'Each watchtower can only submit one pessimistic state');
        require(_numWatchtowerVirtualClaims < _t, 'Watchtower race is complete');

        // _watchtowerLastAutoIncrement[idx] = announcement.autoIncrement;
        _watchtowerLastAutoIncrementVirtual[idx] = announcement.autoIncrement;
        _watchtowerLastValueVirtual[idx] = announcement.Encstate;

        _watchtowerClaimedVirtualClose[idx] = true;
        ++_numWatchtowerVirtualClaims;

        if (announcement.autoIncrement > _maxWatchtowerAutoIncrementVirtualClaim) {
            _maxWatchtowerAutoIncrementVirtualClaim = announcement.autoIncrement;
            _bestAnnouncementVirtual = announcement;
        }
    }

        function pessimisticVirtualChannelClose(RegisterTransaction memory txr, VirtualChannelState memory closingState, VirtualFraudProof[] memory proofs)
    public openOnly {
        require(msg.sender == _alice || msg.sender == _ingrid, 'Only Alice or Ingrid can pessimistically close the channel');
        
        require(_bestAnnouncementVirtual.autoIncrement == closingState.autoIncrement, 'Channel must close at latest state');
        // require(_bestAnnouncementVirtual.Encstate == closingState.Encstate, 'Channel must close at latest state');
        require(closingState.aliceValue <= txr.VchannelValue, 'Channel must conserve monetary value');
        require(_numWatchtowerVirtualClaims >= _t, 'At least 2f+1 watchtower claims are needed for pessimistic close');
        // bytes32 plaintext = bytes32(txr.ValiceValue);
        bytes32 plaintext = keccak256(abi.encode(address(this), txr.ValiceValue));

        //Verify the register transaction
        // require(checkPrefixedSig(txr.Bob, plaintext, txr.bobSig) && 
        // checkPrefixedSig(txr.Alice, plaintext, txr.aliceSig) && 
        // checkPrefixedSig(txr.Ingrid, plaintext, txr.ingridSig), 'All parties must have signed closing state');

        bool test = checkPrefixedSig(txr.Bob, plaintext, txr.bobSig);
        test = checkPrefixedSig(txr.Alice, plaintext, txr.aliceSig); 
        test = checkPrefixedSig(txr.Ingrid, plaintext, txr.ingridSig);
        


        //Verify the closing state
        plaintext = bytes32(closingState.aliceValue);
        // require(checkSig(txr.Bob, plaintext, txr.bobSig) && checkSig(txr.Alice, plaintext, txr.aliceSig), 'Counterparty must have signed closing state');
        test = checkSig(txr.Bob, plaintext, txr.bobSig) && checkSig(txr.Alice, plaintext, txr.aliceSig);
        



        //verify the fraud proof
        for (uint256 i = 0; i < proofs.length; ++i) {
            uint256 idx = proofs[i].watchtowerIdx;
            require(validVirtualFraudProof(proofs[i]), 'Invalid fraud proof');
            // Ensure there's at most one fraud proof per watchtower
            require(_watchtowerFunded[idx], 'Duplicate fraud proof');
            _watchtowerFunded[idx] = false;
        }

        //Save the virtual channel sequence 


        //Change the channel balance
       if (proofs.length <= _f) {
            _alice.transfer(closingState.aliceValue);
            _ingrid.transfer(txr.VchannelValue - closingState.aliceValue);
        }
        else {
            counterparty(msg.sender).transfer(txr.VchannelValue);
        }
        payable(msg.sender).transfer((_collateral * closingState.VchannelValue/_initialChannelValue) * proofs.length);
        _VChannelClosedValue = _VChannelClosedValue +  txr.VchannelValue;

    }
    



    function pessimisticClose(ChannelState memory closingState, ECSignature memory counterpartySig, FraudProof[] memory proofs)
    public openOnly {
        require(closingState.channelValue + _VChannelClosedValue == _initialChannelValue, 'Virtual channel is not closed');
        require(msg.sender == _alice || msg.sender == _ingrid, 'Only Alice or ingrid can pessimistically close the channel');
        require(_bestAnnouncementPayment.autoIncrement == closingState.autoIncrement, 'Channel must close at latest state');
        require(closingState.aliceValue <=
                _initialAliceValue + _initialIngridValue, 'Channel must conserve monetary value');
        require(_numWatchtowerPaymentClaims >= _t, 'At least 2f+1 watchtower claims are needed for pessimistic close');
        bytes32 plaintext = keccak256(abi.encode(address(this), closingState));
        // require(checkPrefixedSig(counterparty(msg.sender), plaintext, counterpartySig), 'Counterparty must have signed closing state');
        bool check = checkPrefixedSig(counterparty(msg.sender), plaintext, counterpartySig);


        for (uint256 i = 0; i < proofs.length; ++i) {
            uint256 idx = proofs[i].watchtowerIdx;
            require(validFraudProof(proofs[i]), 'Invalid fraud proof');
            // Ensure there's at most one fraud proof per watchtower
            require(_watchtowerFunded[idx], 'Duplicate fraud proof');
            _watchtowerFunded[idx] = false;
        }

        _numHonestClosingWatchtowers = _n - uint8(proofs.length);
        _phase = BrickPhase.Closed;

        if (proofs.length <= _f) {
            _alice.transfer(closingState.aliceValue);
            _ingrid.transfer(closingState.channelValue - closingState.aliceValue);
        }
        else {
            counterparty(msg.sender).transfer(closingState.channelValue);
        }
        payable(msg.sender).transfer(_collateral * (closingState.channelValue/_initialChannelValue) * proofs.length);
    }

    function watchtowerRedeemCollateral(uint256 idx)
    external atPhase(BrickPhase.Closed) {
        require(msg.sender == _watchtowers[idx], 'This is not the watchtower claimed');
        require(_watchtowerFunded[idx], 'Malicious watchtower tried to redeem collateral; or double collateral redeem');

        _watchtowerFunded[idx] = false;
        _watchtowers[idx].transfer(_collateral + FEE / _numHonestClosingWatchtowers);
    }

    function checkSig(address pk, bytes32 plaintext, ECSignature memory sig)
    public pure returns(bool) {
        return ecrecover(plaintext, sig.v, sig.r, sig.s) == pk;
    }

    function checkPrefixedSig(address pk, bytes32 message, ECSignature memory sig)
    public pure returns(bool) {
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));

        return ecrecover(prefixedHash, sig.v, sig.r, sig.s) == pk;
    }


    function validAnnouncement(Announcement memory announcement)
    public returns(bool) {//verify the validity of wardens' messages

        //Already verify to be valid
        if (announcementAutoIncrementSigned[announcement.autoIncrement]) {
            return true;
        }
        bytes32 message = keccak256(abi.encode(address(this), announcement.autoIncrement));

        if (checkPrefixedSig(_alice, message, announcement.aliceSig) &&
            checkPrefixedSig(_ingrid, message, announcement.ingridSig)) {
            announcementAutoIncrementSigned[announcement.autoIncrement] = true;
            return true;
        }
        return true;
    }

    function validVirtualAnnouncement(VirtualAnnouncement memory announcement)
    public returns(bool) {
        if (VirtualannouncementStateSigned[announcement.autoIncrement]) {
            return true;
        }

        bytes32 message = keccak256(abi.encode(address(this), announcement.autoIncrement));

        if (checkSig(_alice, message, announcement.aliceSig) &&
            checkSig(_bob, message, announcement.bobSig)) {
            VirtualannouncementStateSigned[announcement.autoIncrement] = true;
            return true;
        }
        return true;
    }

    function counterparty(address party)
    internal view returns (address payable) {
        if (party == _alice) {
            return _ingrid;
        }
        return _alice;
    }

    function staleClaim(FraudProof memory proof)
    internal view returns (bool) {
        uint256 watchtowerIdx = proof.watchtowerIdx;

        return proof.statePoint.autoIncrement >
               _watchtowerLastAutoIncrement[watchtowerIdx];
    }

    function staleVirtualClaim(VirtualFraudProof memory proof)
    internal view returns (bool) {
        uint256 watchtowerIdx = proof.watchtowerIdx;

        return (proof.statePoint.autoIncrement >
               _watchtowerLastAutoIncrement[watchtowerIdx]) || ((proof.statePoint.autoIncrement ==
               _watchtowerLastAutoIncrement[watchtowerIdx]) && keccak256(abi.encode(address(this), proof.statePoint.Encstate)) != keccak256(abi.encode(address(this), _watchtowerLastValueVirtual[watchtowerIdx])));
    }

    function validFraudProof(FraudProof memory proof)
    public view returns (bool) {
        return checkPrefixedSig(
            _watchtowers[proof.watchtowerIdx],
            keccak256(abi.encode(address(this), proof.statePoint.autoIncrement)),
            proof.watchtowerSig
        ) && staleClaim(proof);
    }

    function validVirtualFraudProof(VirtualFraudProof memory proof)
    public view returns (bool) {
        return checkPrefixedSig(
            _watchtowers[proof.watchtowerIdx],
            keccak256(abi.encode(address(this), proof.statePoint.autoIncrement)),
            proof.watchtowerSig
        ) && checkPrefixedSig(
            _watchtowers[proof.watchtowerIdx],
            keccak256(abi.encode(address(this), proof.statePoint.Encstate)),
            proof.watchtowerSig
        ) &&  staleVirtualClaim(proof);
    }
}
