// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
// import {VRFConsumerBase} from "@bisonai/orakl-contracts/src/v0.1/VRFConsumerBase.sol";
// import {IVRFCoordinator} from "@bisonai/orakl-contracts/src/v0.1/interfaces/IVRFCoordinator.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract Lottery is Ownable, VRFConsumerBaseV2,ReentrancyGuard {
    VRFCoordinatorV2Interface COORDINATOR;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint64 private s_subscriptionId;
    address private vrfCoordinator = 0x271682DEB8C4E0901D1a1550aD2e64D568E69909;
    bytes32 private keyHash = 0xd4bb89654db74673a187bd804519e65e3f71a52bc55f11da7601a13dcf505314;
    uint16 private requestConfirmations = 3;
    uint32 private numWords =  6;
    uint32 private callbackGasLimit = 2500000;

    struct RequestStatus{
        bool fulfilled;
        bool exists;
        uint[] randomWords;
    }
    mapping (uint256 => RequestStatus) public  s_requests;
    uint256 public lastRequestId;

    //Lottery Settings
    IERC20 paytoken;
    uint256 public  currentLotteryId;
    uint256 public  currentTicketId;
    uint256 public  ticketPrice = 10 ether; //giá vé
    uint256 public  serviceFee = 3000; // Điểm cơ bản 3000 là 30%
    uint256 public  numberWinner;

    enum Status{
        Close,
        Open,
        Claimable
    }

    struct Lotteries{
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 firstTicketId;
        uint256 transferJackpot;
        uint256 lastTicketId;
        uint[6] winningNumbers;
        uint256 totalPayout;
        uint256 commision;
        uint256 winnerCount;
    }
    struct Ticket {
        uint256 ticketId;
        address owner;
        uint[6] chooseNumbers;
    }

    mapping (uint256 => Lotteries) private  _lotteries;
    mapping (uint256 => Ticket) private _tickets;
    mapping (uint256 => mapping (uint32 => uint256)) private _numberTicketPerLotteryId;
    mapping (address => mapping (uint256 => uint256[])) private _userTicketIdsPerLotteryId;
    mapping (address => mapping (uint256 => uint256)) public  _winnersPerLotteryId;

    event LotteryWinnerNumber(uint256 indexed lotteryId, uint[6] finnalNumber);

    event LotteryClose(
        uint256 indexed lotteryId,
        uint256 lastTicketId
    );
    event LotteryOpen(
        uint256 indexed lotteryId,
        uint256 startTime,
        uint256 endTime,
        uint256 ticketPrice,
        uint256 firstTicketId,
        uint256 transferJackpot,
        uint256 lastTicketId,
        uint256 totalPayout
    );
    event TicketsPurChase(
        address indexed  buyer,
        uint256 indexed lotteryId,
        uint[6] chooseNumbers
    );


    constructor(
        uint64 subscriptionId,
        address initialOwner,
        IERC20 _paytoken
       
    ) VRFConsumerBaseV2(vrfCoordinator) Ownable(initialOwner){
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_subscriptionId = subscriptionId;
        paytoken = _paytoken;
    }

    /**
        Open Lottery
    */
    function openLottery() external  onlyOwner nonReentrant {
        currentLotteryId++;
        currentTicketId++;
        uint256 fundJackpot = (_lotteries[currentLotteryId].transferJackpot).add(1000 ether);
        uint256 transferJackpot;
        uint256 totalLayout;
        uint256 lastTicketId;
        uint256 endTime;
        _lotteries[currentLotteryId] = Lotteries({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: 100,
            firstTicketId: currentTicketId,
            transferJackpot: fundJackpot,
            winningNumbers: [uint(0), uint(0), uint(0), uint(0), uint(0), uint(0)],
            lastTicketId: currentTicketId,
            totalPayout: 0,
            commision: 0,
            winnerCount: 0
        });
        emit LotteryOpen(
            currentLotteryId, 
            block.timestamp, 
            endTime, 
            ticketPrice, 
            currentTicketId, 
            transferJackpot, 
            lastTicketId, 
            totalLayout
        ); 
    }
    /**
        Buy Ticket
        0. Mua vé
        1. Tính giá Hoa hồng cho mỗi lần bán
        2. Update lại tổng transferJackpot của Lottery mỗi lần bán được 7 + 7 + 7 ... = transferJackpot
        3. Theo dõi thông tin số vé mà 1 người đã mua "1 người mua nhiều vé"
        4. Lưu lại Thông tin vé mà người dùng đã mua vào mapping _tickets
        5. Update lại giá trị lastTicketId của Lottery và bắn ra 1 sự kiện đã mua được vé thành công
    */
    function buyTickets(uint[6] calldata numbers) public  payable nonReentrant  {
        uint256 walletBalance = paytoken.balanceOf(msg.sender);
        require(walletBalance >= ticketPrice, "Funds not available to complete transaction");
        paytoken.transferFrom(address(msg.sender), address(this), ticketPrice);

        /**
        * --------Calculate Commision Fee--------
        * Hãy nhận hoa hồng nền tảng cho mỗi lần bán vé.
        * Giả sử: Giá vé là 10 ether,
        * Phí dịch vụ là 30% (hoặc 3000) Tìm biến lúc đầu
        * 
        * Formula is: 
        *   ticket Price x serviceFee / 10000
        *
        *   10 x 3000 / 10000 = 3
        *
        *   3 là số token kiếm được trên nền tảng từ mỗi lần bán vé.
        */
        uint256 commisionFee = (ticketPrice.mul(serviceFee).div(10000)); //mul <=> * | div <=> /

        _lotteries[currentLotteryId].commision += commisionFee;
        uint256 netEarn = ticketPrice - commisionFee;
        _lotteries[currentLotteryId].transferJackpot += netEarn;


        /**
        Lets store each ticket number array referenced to the buyer's wallet
        mapping(address => mapping(uint256 => uint256[])) private _userTicketIdsPerLotteryId;
        */
        _userTicketIdsPerLotteryId[msg.sender][currentLotteryId].push(currentTicketId);

        _tickets[currentTicketId] = Ticket({
            ticketId: currentTicketId,
            owner: msg.sender,
            chooseNumbers: numbers
        });
        currentTicketId++;
        _lotteries[currentLotteryId].lastTicketId = currentTicketId;
        emit TicketsPurChase(msg.sender, currentLotteryId, numbers);
    }
    /**
    *   Đóng xổ số
    */
    function closeLottery() external onlyOwner{
        require(_lotteries[currentLotteryId].status == Status.Open, "Lottery not open");
        require(block.timestamp > _lotteries[currentLotteryId].endTime, "Lottery not over");


        /**
            Id yêu cầu Lưu trữ Id yêu cầu ChainLink VRF, Id này được tìm nạp sau khi chúng tôi thực thi drawNumbers()
            và từ đó chúng ta sẽ lấy được một số ngẫu nhiên mà chúng ta có thể sử dụng để lấy được các con số trúng thưởng.
        */
        uint256 requestId;
        /**
        Cuối cùng, hãy gọi ChainLink VRFv2 và nhận các số trúng thưởng từ trình tạo ngẫu nhiên.
         */
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        lastRequestId = requestId;
        emit LotteryClose(currentLotteryId, currentTicketId);
        
    }
    /**
        Tạo số
    */
    function drawNumbers() external  onlyOwner nonReentrant (){
        require(_lotteries[currentLotteryId].status == Status.Close, "Lottory not close");
        uint256[] memory numArray = s_requests[lastRequestId].randomWords;
        uint num1 = numArray[0] % 55 + 1;
        uint num2 = numArray[0] % 55 + 1;
        uint num3 = numArray[0] % 55 + 1;
        uint num4 = numArray[0] % 55 + 1;
        uint num5 = numArray[0] % 55 + 1;
        uint num6 = numArray[0] % 55 + 1;
        uint[6] memory finalNumbers = [num1,num2,num3,num4,num5,num6];
        _lotteries[currentLotteryId].winningNumbers = finalNumbers;
        _lotteries[currentLotteryId].totalPayout = _lotteries[currentLotteryId].transferJackpot;

    }

    //Count Winners
    function countWinners() external  onlyOwner {
        require(_lotteries[currentLotteryId].status == Status.Close, "Lottery not close");
        require(_lotteries[currentLotteryId].status != Status.Claimable, "Lottery Already Counted");
        delete numberWinner;
        uint256 firstTicketId = _lotteries[currentLotteryId].firstTicketId;
        uint256 lastTicketId = _lotteries[currentLotteryId].lastTicketId;
        uint[6] memory winOrder;
        winOrder = sortArrays(_lotteries[currentLotteryId].winningNumbers);
        bytes32 encodeWin = keccak256(abi.encodePacked(winOrder));
        uint256 i = firstTicketId;
        for (i; i < lastTicketId; i++) 
        {
            address buyer = _tickets[i].owner;
            uint[6] memory userNum = _tickets[i].chooseNumbers;
            bytes32 encodeUser = keccak256(abi.encodePacked(userNum));
            if(encodeUser == encodeWin){
                numberWinner ++;
                _lotteries[currentLotteryId].winnerCount = numberWinner;
                _winnersPerLotteryId[buyer][currentLotteryId] = 1;
            }
        }
        if(numberWinner == 0){
            uint256 nextLottoId = (currentLotteryId).add(1);
            _lotteries[nextLottoId].transferJackpot = _lotteries[currentLotteryId].totalPayout;
        }
        _lotteries[currentLotteryId].status = Status.Claimable;
    }
    //Sắp xếp
    function sortArrays(uint[6] memory numbers) internal pure returns (uint[6] memory) {
        bool swap;
        for (uint i = 1; i < numbers.length; i++ ) 
        {
            swap = false;
            for (uint j = 0; j < numbers.length - i; j++) 
            {
                uint next = numbers[j + 1];
                uint actual = numbers[j];
                if(next < actual){
                    numbers[j] = next;
                    numbers[j + 1] = actual;
                    swap = true;
                }
            }
            if(!swap){
                return numbers;
            }
        }
        return  numbers;
    }


    //Claim Prize
    function claimPrize(uint256 _lottoId) external  nonReentrant {
        require(_lotteries[_lottoId].status == Status.Claimable,"Not Payable");
        require(_lotteries[_lottoId].winnerCount > 0, "Not Payable");
        require(_winnersPerLotteryId[msg.sender][_lottoId] == 1,"Not Payable");
        uint256 winners = _lotteries[_lottoId].winnerCount;
        uint256 payout = (_lotteries[_lottoId].totalPayout).div(winners);
        paytoken.safeTransfer(msg.sender,payout);
        _winnersPerLotteryId[msg.sender][_lottoId] = 0;
    }
    /**
        Chainlink VRFv2 Specific functions required in the smart contract for full functionality.
    */

    function getRequestStatus(
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[lastRequestId].exists, "request not found");
        RequestStatus memory request = s_requests[lastRequestId];
        return (request.fulfilled, request.randomWords);
    }


    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
    }



    /**
    Lottery additional functions
    */
    function viewTickets(uint256 ticketId) external view returns (address, uint[6] memory) {
        address buyer;
        buyer = _tickets[ticketId].owner;
        uint[6] memory numbers;
        numbers = _tickets[ticketId].chooseNumbers;
        return (buyer, numbers); 
    }
    function viewLottery(uint256 _lotteryId) external view returns (Lotteries memory) {
        return _lotteries[_lotteryId];
    }

    function getBalance() external view onlyOwner returns(uint256) {
        return paytoken.balanceOf(address(this));
    }

    function fundContract(uint256 amount) external onlyOwner {
        paytoken.safeTransferFrom(address(msg.sender), address(this), amount);
    }

    function withdraw() public onlyOwner() {
      paytoken.safeTransfer(address(msg.sender), (paytoken.balanceOf(address(this))));
    }
}
