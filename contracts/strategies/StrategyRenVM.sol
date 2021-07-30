// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

import 'oz410/token/ERC20/IERC20.sol';
import 'oz410/math/SafeMath.sol';
import 'oz410/utils/Address.sol';
import 'oz410/token/ERC20/SafeERC20.sol';
import '../interfaces/IStrategy.sol';
import '../interfaces/IyVault.sol';
import '../interfaces/IWETH.sol';
import {StrategyAPI} from '../interfaces/IStrategy.sol';
import {IController} from '../interfaces/IController.sol';
import {IUniswapV2Router02} from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import {ICurvePool} from '../interfaces/ICurvePool.sol';
import {IZeroModule} from '../interfaces/IZeroModule.sol';
import {console} from 'hardhat/console.sol';

contract StrategyRenVM {
	using SafeERC20 for IERC20;
	using Address for address;
	using SafeMath for uint256;

	address public constant curveBTCPool = 0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714;
	address public constant curveTriPool = 0x80466c64868E1ab14a1Ddf27A676C3fcBE638Fe5;
	address public constant vault = address(0xA696a63cc78DfFa1a63E9E50587C197387FF6C7E);
	address public constant nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

	address public constant want = address(0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D);
	int128 public constant wantIndex = 0;

	address public constant vaultWant = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
	int128 public constant vaultWantIndex = 1;

	string public constant name = '0confirmation RenVM Strategy';
	bool public constant isActive = true;

	uint256 public constant wantReserve = 200000000;
	uint256 public constant gasReserve = uint256(5 ether);
	address public immutable controller;
	address public governance;
	address public strategist;

	modifier onlyController() {
		require(msg.sender == controller, '!controller');
		_;
	}

	constructor(address _controller) {
		governance = msg.sender;
		strategist = msg.sender;
		controller = _controller;
	}

	receive() external payable {}

	function swapBTC(
		address _tokenIn,
		uint256 _amountIn,
		int128 _indexIn,
		int128 _indexOut
	) internal returns (uint256) {
		IERC20(_tokenIn).safeApprove(address(curveBTCPool), _amountIn);
		uint256 _expectedAmountOut = ICurvePool(curveBTCPool).get_dy(_indexIn, _indexOut, _amountIn).sub(1); //Subtract 1 to avoid minimum token exchange errors
		ICurvePool(curveBTCPool).exchange(_indexIn, _indexOut, _amountIn, _expectedAmountOut);
		return _expectedAmountOut;
	}

	function swapGas(uint256 _amountIn) internal returns (uint256) {
		IERC20(want).safeApprove(address(curveTriPool), _amountIn);
		uint256 _expectedAmountOut = ICurvePool(curveTriPool).get_dy(1, 2, _amountIn).sub(1); //Subtract 1 for minimum
		ICurvePool(curveTriPool).exchange(1, 2, _amountIn, _expectedAmountOut);
		IWETH(nativeWrapper).withdraw(_expectedAmountOut);
		return _expectedAmountOut;
	}

	function deposit() external virtual {
		console.log('Calling deposit..');
		//First conditional handles having too much of want in the Strategy
		uint256 _want = IERC20(want).balanceOf(address(this)); //amount of tokens we want
		if (_want > wantReserve) {
			uint256 _amountOut = swapBTC(want, _want.sub(wantReserve), wantIndex, vaultWantIndex);
			IERC20(vaultWant).safeApprove(address(vault), _amountOut);
			IyVault(vault).deposit(_amountOut);
		}
		//Second conditional handles having too little of gasWant in the Strategy
		uint256 _gasWant = address(this).balance;
		if (_gasWant < gasReserve) {
			uint256 _sharesDeficit = estimateShares(gasReserve.sub(_gasWant));
			uint256 _amountOut = IyVault(vault).withdraw(_sharesDeficit);
			swapGas(_amountOut);
		}
		console.log('Deposit called');
	}

	function _withdraw(uint256 _amount, address _asset) private returns (uint256) {
		require(_asset == want || _asset == vaultWant, 'asset not supported');
		if (_asset == want) {
			//then we can't directly withdraw it
			_amount = ICurvePool(curveBTCPool).get_dy(vaultWantIndex, wantIndex, _amount).sub(1);
		}
		uint256 _shares = estimateShares(_amount);
		_amount = IyVault(vault).withdraw(_shares);
		if (_asset == want) {
			_amount = swapBTC(vaultWant, _amount, vaultWantIndex, wantIndex);
		}
		return _amount;
	}

	function permissonedEther(address payable _target, uint256 _amount) external virtual onlyController {
		if (_amount > gasReserve) {
			uint256 _sharesDeficit = estimateShares(_amount);
			uint256 _amountOut = IyVault(vault).withdraw(_sharesDeficit);
			_amount = swapGas(_amountOut);
		}
		_target.transfer(_amount);
	}

	function withdraw(uint256 _amount) external virtual onlyController {
		IERC20(want).safeTransfer(address(controller), _withdraw(_amount, want));
	}

	function withdrawAll() external virtual onlyController {
		IERC20(want).safeTransfer(address(controller), _withdraw(IERC20(vault).balanceOf(address(this)), want));
	}

	function balanceOf() external view virtual returns (uint256) {
		return IyVault(vault).balanceOf(address(this));
	}

	function estimateShares(uint256 _amount) internal virtual returns (uint256) {
		return _amount.mul(10**8).div(IyVault(vault).pricePerShare());
	}

	function permissionedSend(address _module, uint256 _amount) external virtual onlyController returns (uint256) {
		uint256 _reserve = IERC20(want).balanceOf(address(this));
		address _want = IZeroModule(_module).want();
		if (_amount > _reserve || _want != want) {
			_amount = _withdraw(_amount, _want);
		}
		IERC20(_want).safeTransfer(_module, _amount);
		return _amount;
	}
}
