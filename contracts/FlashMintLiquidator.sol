// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;



import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interface/IERC3156FlashLender.sol";
import "./interface/IERC3156FlashBorrower.sol";
import "@morphodao/morpho-core-v1/contracts/compound/interfaces/IMorpho.sol";
import "@morphodao/morpho-core-v1/contracts/compound/interfaces/compound/ICompound.sol";


import "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import "@morphodao/morpho-core-v1/contracts/compound/libraries/CompoundMath.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FlashMintLiquidator is IERC3156FlashBorrower, Ownable, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using CompoundMath for uint256;


    struct FlashLoansParams {
        address _poolTokenBorrowedAddress;
        address _poolTokenCollateralAddress;
        address _underlyingTokenBorrowedAddress;
        address _underlyingTokenCollateralAddress;
        address _borrower;
        uint256 _repayAmount;
        uint256 seized;
        uint256 repayFlashloans;
        uint24 firstSwapFees;
        uint24 secondSwapFees;
    }
    struct LiquidateParams {
        ERC20 collateralUnderlying;
        ERC20 borrowedUnderlying;
        uint256 collateralBalanceBefore;
        uint256 borrowedTokenBalanceBefore;
        uint256 amountSeized;
    }
    /// EVENTS ///

    event Liquidated(
        address indexed liquidator,
        address borrower,
        address indexed poolTokenBorrowedAddress,
        address indexed poolTokenCollateralAddress,
        uint256 amount,
        uint256 seized,
        bool usingFlashLoans
    );

    event FlashLoan(
        address indexed _initiator,
        uint256 amount
    );

    event LiquidatorAdded(
        address indexed _liquidatorAdded
    );

    event LiquidatorRemoved(
        address indexed _liquidatorRemoved
    );

    event Withdrawn(
        address indexed sender,
        address indexed receiver,
        address indexed underlyingAddress,
        uint256 amount
    );

    event OverSwappedDai(
        uint256 amount
    );

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint24 fees
    );

    uint256 public constant BASIS_POINTS = 10000;

    IMorpho public immutable morpho;
    ICToken public immutable cDai;
    ISwapRouter public immutable uniswapV3Router;
    IERC3156FlashLender public immutable lender;

    mapping(address => bool) public isLiquidator;

    constructor (
        IERC3156FlashLender lender_,
        ISwapRouter uniswapV3Router_,
        IMorpho morpho_,
        ICToken cDai_
    ) {
        lender = lender_;
        morpho = morpho_;
        cDai = cDai_;
        uniswapV3Router = uniswapV3Router_;
        isLiquidator[msg.sender] = true;
    }


    function liquidate(
        address _poolTokenBorrowedAddress,
        address _poolTokenCollateralAddress,
        address _borrower,
        uint256 _repayAmount,
        bool _stakeTokens,
        uint24 _firstSwapFees,
        uint24 _secondSwapFees
    ) external nonReentrant {
        LiquidateParams memory liquidateParams;
        liquidateParams.collateralUnderlying = ERC20(ICToken(_poolTokenCollateralAddress).underlying());
        liquidateParams.collateralBalanceBefore = liquidateParams.collateralUnderlying.balanceOf(address(this));

        liquidateParams.borrowedUnderlying = ERC20(ICToken(_poolTokenBorrowedAddress).underlying());
        if(_stakeTokens && isLiquidator[msg.sender] ) {
            // only for setted liquidators
            liquidateParams.borrowedTokenBalanceBefore = ERC20(ICToken(_poolTokenBorrowedAddress).underlying()).balanceOf(address(this));
            if(liquidateParams.borrowedTokenBalanceBefore >= _repayAmount) {
                liquidateParams.borrowedUnderlying.safeApprove(address(morpho), _repayAmount);
                morpho.liquidate(_poolTokenBorrowedAddress, _poolTokenCollateralAddress, _borrower, _repayAmount);
                liquidateParams.amountSeized = liquidateParams.collateralUnderlying.balanceOf(address(this)) - liquidateParams.collateralBalanceBefore;
                emit Liquidated(
                    msg.sender,
                    _borrower,
                    _poolTokenBorrowedAddress,
                    _poolTokenCollateralAddress,
                    _repayAmount,
                    liquidateParams.amountSeized,
                    false
                );
                return;
            }
        }
        ERC20 dai;
        uint256 daiToFlashLoan;
        {
            ICompoundOracle oracle = ICompoundOracle(IComptroller(morpho.comptroller()).oracle());
            uint256 daiPrice = oracle.getUnderlyingPrice(address(cDai));
            uint256 borrowedTokenPrice = oracle.getUnderlyingPrice(_poolTokenBorrowedAddress);
            daiToFlashLoan = _repayAmount.mul(borrowedTokenPrice).div(daiPrice);
            dai = ERC20(cDai.underlying());
            uint256 fee = lender.flashFee(address(dai), daiToFlashLoans);
            dai.safeApprove(address(lender), daiToFlashLoans + fee);
        }

        bytes memory data = abi.encode(
            _poolTokenBorrowedAddress,
            _poolTokenCollateralAddress,
            address(liquidateParams.borrowedUnderlying),
            address(liquidateParams.collateralUnderlying),
            _borrower,
            _repayAmount,
            _firstSwapFees,
            _secondSwapFees
        );
        uint256 balanceBefore = liquidateParams.collateralUnderlying.balanceOf(address(this));
        lender.flashLoan(this, address(dai), daiToFlashLoan, data);
        emit FlashLoan(
            msg.sender,
            daiToFlashLoan
        );
        liquidateParams.amountSeized = liquidateParams.collateralUnderlying.balanceOf(address(this)) - balanceBefore;

        if(!_stakeTokens) {
            liquidateParams.borrowedUnderlying.safeTransfer(msg.sender, liquidateParams.amountSeized);
        }

    }

    /// @dev ERC-3156 Flash loan callback
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(
            msg.sender == address(lender),
            "FlashBorrower: Untrusted lender"
        );
        require(
            initiator == address(this),
            "FlashBorrower: Untrusted loan initiator"
        );
        FlashLoansParams memory flashLoansParams;
        (
            flashLoansParams._poolTokenBorrowedAddress,
            flashLoansParams._poolTokenCollateralAddress,
            flashLoansParams._underlyingTokenBorrowedAddress,
            flashLoansParams._underlyingTokenCollateralAddress,
            flashLoansParams._borrower,
            flashLoansParams._repayAmount,
            flashLoansParams.firstSwapFees,
            flashLoansParams.secondSwapFees
        ) = abi.decode(data, (address,address,address,address,address,uint256,uint24,uint24));

        flashLoansParams.repayFlashloans = amount + fee; // keep the minimum amount to repay flash loan
        if(token != flashLoansParams._underlyingTokenBorrowedAddress) {
            // first swap if needed
            ERC20(token).safeApprove(address(uniswapV3Router), amount);

            uint amountOutMinimumWithSlippage = flashLoansParams._repayAmount * (BASIS_POINTS - 100) / BASIS_POINTS;
            ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: flashLoansParams._underlyingTokenBorrowedAddress,
            fee: flashLoansParams.firstSwapFees,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: amountOutMinimumWithSlippage,
            // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
            sqrtPriceLimitX96: 0
            });
            {
                uint256 swapped = uniswapV3Router.exactInputSingle(params);
                if(swapped > flashLoansParams._repayAmount) {
                    // this is a bonus due to over swapped tokens
                    emit OverSwappedDai(swapped - flashLoansParams._repayAmount);
                } else {
                    flashLoansParams._repayAmount = swapped;
                }
                emit Swapped(
                    token,
                    flashLoansParams._underlyingTokenBorrowedAddress,
                    amount,
                    swapped,
                    flashLoansParams.firstSwapFees
                );
            }
        }

        uint256 balanceBefore = ERC20(flashLoansParams._underlyingTokenCollateralAddress).balanceOf(address(this));

        ERC20(flashLoansParams._underlyingTokenBorrowedAddress).safeApprove(address(morpho), flashLoansParams._repayAmount);
        morpho.liquidate(flashLoansParams._poolTokenBorrowedAddress, flashLoansParams._poolTokenCollateralAddress, flashLoansParams._borrower, flashLoansParams._repayAmount);

        flashLoansParams.seized = ERC20(flashLoansParams._underlyingTokenCollateralAddress).balanceOf(address(this)) - balanceBefore;

        if(flashLoansParams._underlyingTokenCollateralAddress != token) {
            uint256 amountInMaximum;
            {
                ICompoundOracle oracle = ICompoundOracle(IComptroller(morpho.comptroller()).oracle());
                amountInMaximum = flashLoansParams.repayFlashloans.mul(oracle.getUnderlyingPrice(address(cDai))).div(oracle.getUnderlyingPrice(address(flashLoansParams._poolTokenCollateralAddress))) * (BASIS_POINTS + 100) / BASIS_POINTS;
                amountInMaximum = amountInMaximum > flashLoansParams.seized ? flashLoansParams.seized : amountInMaximum;
            }
            // require(amountInMaximum >= flashLoansParams.seized, "FlashBorrower: Cannot assume slippage");

            ERC20(flashLoansParams._underlyingTokenCollateralAddress).safeApprove(address(uniswapV3Router), amountInMaximum);
            ISwapRouter.ExactOutputSingleParams memory outputParams =
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: flashLoansParams._underlyingTokenCollateralAddress,
                    tokenOut: token,
                    fee: flashLoansParams.secondSwapFees,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: flashLoansParams.repayFlashloans,
                    amountInMaximum: amountInMaximum,
                    // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact output amount.
                    sqrtPriceLimitX96: 0
                });
            uint256 swappedIn = uniswapV3Router.exactOutputSingle(outputParams);

            emit Swapped(
                flashLoansParams._underlyingTokenCollateralAddress,
                token,
                swappedIn,
                flashLoansParams.repayFlashloans,
                flashLoansParams.secondSwapFees
            );
        }
        emit Liquidated(
            flashLoansParams._liquidator,
            flashLoansParams._borrower,
            flashLoansParams._poolTokenBorrowedAddress,
            flashLoansParams._poolTokenCollateralAddress,
            flashLoansParams._repayAmount,
            flashLoansParams.seized,
            false
        );
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function addLiquidator(address _newLiquidator) external onlyOwner {
        isLiquidator[_newLiquidator] = true;
        emit LiquidatorAdded(_newLiquidator);
    }

    function removeLiquidator(address _liquidatorToRemove) external onlyOwner {
        isLiquidator[_liquidatorToRemove] = false;
        emit LiquidatorRemoved(_liquidatorToRemove);
    }


    function deposit(address _underlyingAddress, uint256 _amount) external {
        ERC20(_underlyingAddress).safeTransferFrom(msg.sender, address(this), _amount);
    }

    function withdraw(address _underlyingAddress, address _receiver, uint256 _amount ) external onlyOwner {
        ERC20(_underlyingAddress).safeTransfer(_receiver, _amount);
        emit Withdrawn(msg.sender, _receiver, _underlyingAddress, _amount);
    }

}
