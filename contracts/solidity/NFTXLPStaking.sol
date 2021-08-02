// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interface/INFTXVaultFactory.sol";
import "./interface/INFTXFeeDistributor.sol";
import "./token/IERC20Upgradeable.sol";
import "./util/SafeERC20Upgradeable.sol";
import "./util/PausableUpgradeable.sol";
import "./util/Address.sol";
import "./proxy/ClonesUpgradeable.sol";
import "./proxy/Initializable.sol";
import "./StakingTokenProvider.sol";
import "./token/RewardDistributionTokenUpgradeable.sol";

// Author: 0xKiwi.

// Pausing codes for LP staking are:
// 10: Deposit

contract NFTXLPStaking is PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    INFTXVaultFactory public nftxVaultFactory;
    RewardDistributionTokenUpgradeable public rewardDistTokenImpl;
    StakingTokenProvider public stakingTokenProvider;

    event PoolCreated(uint256 vaultId, address pool);
    event PoolUpdated(uint256 vaultId, address pool);
    event FeesReceived(uint256 vaultId, uint256 amount);

    struct StakingPool {
        address stakingToken;
        address rewardToken;
    }
    mapping(uint256 => StakingPool) public vaultStakingInfo;

    function __NFTXLPStaking__init(address _stakingTokenProvider) external initializer {
        __Ownable_init();
        require(_stakingTokenProvider != address(0), "Provider != address(0)");
        rewardDistTokenImpl = new RewardDistributionTokenUpgradeable();
        rewardDistTokenImpl.__RewardDistributionToken_init(IERC20Upgradeable(address(0)), "", "");
        stakingTokenProvider = StakingTokenProvider(_stakingTokenProvider);
    }

    modifier onlyAdmin() {
        require(msg.sender == owner() || msg.sender == nftxVaultFactory.feeDistributor(), "LPStaking: Not authorized");
        _;
    }

    function setNFTXVaultFactory(address newFactory) external onlyOwner {
        require(newFactory != address(0));
        nftxVaultFactory = INFTXVaultFactory(newFactory);
    }

    function setStakingTokenProvider(address newProvider) external onlyOwner {
        require(newProvider != address(0));
        stakingTokenProvider = StakingTokenProvider(newProvider);
    }

    // Consider changing LP staking to take vault id into consideration, and access data from there.
    function addPoolForVault(uint256 vaultId) external onlyAdmin {
        require(address(nftxVaultFactory) != address(0), "LPStaking: Factory not set");
        require(vaultStakingInfo[vaultId].stakingToken == address(0), "LPStaking: Pool already exists");
        address _rewardToken = nftxVaultFactory.vault(vaultId);
        address _stakingToken = stakingTokenProvider.stakingTokenForVaultToken(_rewardToken);
        StakingPool memory pool = StakingPool(_stakingToken, _rewardToken);
        vaultStakingInfo[vaultId] = pool;
        address newRewardDistToken = _deployDividendToken(pool);
        emit PoolCreated(vaultId, newRewardDistToken);
    }

    function updatePoolForVaults(uint256[] calldata vaultIds) external {
        for (uint256 i = 0; i < vaultIds.length; i++) {
            updatePoolForVault(vaultIds[i]);
        }
    }

    // In case the provider changes, this lets the pool be updated. Anyone can call it.
    function updatePoolForVault(uint256 vaultId) public {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        // Not letting people use this function to create new pools.
        require(pool.stakingToken != address(0), "LPStaking: Pool doesn't exist");
        address _stakingToken = stakingTokenProvider.stakingTokenForVaultToken(pool.rewardToken);
        // If the pool is already deployed, ignore the update.
        address addr = address(_rewardDistributionTokenAddr(pool));
        if (isContract(addr)) {
            return;
        }
        StakingPool memory newPool = StakingPool(_stakingToken, pool.rewardToken);
        vaultStakingInfo[vaultId] = newPool;
        address newRewardDistToken = _deployDividendToken(newPool);
        emit PoolUpdated(vaultId, newRewardDistToken);
    }

    function receiveRewards(uint256 vaultId, uint256 amount) external onlyAdmin returns (bool) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        if (pool.stakingToken == address(0)) {
            // In case the pair is updated, but not yet 
            return false;
        }
        
        RewardDistributionTokenUpgradeable rewardDistToken = _rewardDistributionTokenAddr(pool);
        // Don't distribute rewards unless there are people to distribute to.
        // Also added here if the distribution token is not deployed, just forfeit rewards for now.
        if (!isContract(address(rewardDistToken)) || rewardDistToken.totalSupply() == 0) {
            return false;
        }
        // We "pull" to the dividend tokens so the vault only needs to approve this contract.
        IERC20Upgradeable(pool.rewardToken).safeTransferFrom(msg.sender, address(rewardDistToken), amount);
        rewardDistToken.distributeRewards(amount);
        emit FeesReceived(vaultId, amount);
        return true;
    }

    function deposit(uint256 vaultId, uint256 amount) external {
        onlyOwnerIfPaused(10);
        // Check the pool in case its been updated.
        updatePoolForVault(vaultId);
        StakingPool memory pool = vaultStakingInfo[vaultId];
        _deposit(pool, amount);
    }

    function exit(uint256 vaultId) external {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        _claimRewards(pool, msg.sender);
        _withdraw(pool, balanceOf(vaultId, msg.sender), msg.sender);
    }

    function emergencyExitAndClaim(address _stakingToken, address _rewardToken) external {
        StakingPool memory pool = StakingPool(_stakingToken, _rewardToken);
        RewardDistributionTokenUpgradeable dist = _rewardDistributionTokenAddr(pool);
        require(isContract(address(dist)), "Not a pool");
        _claimRewards(pool, msg.sender);
        _withdraw(pool, dist.balanceOf(msg.sender), msg.sender);
    }

    function emergencyExit(address _stakingToken, address _rewardToken) external {
        StakingPool memory pool = StakingPool(_stakingToken, _rewardToken);
        RewardDistributionTokenUpgradeable dist = _rewardDistributionTokenAddr(pool);
        require(isContract(address(dist)), "Not a pool");
        _withdraw(pool, dist.balanceOf(msg.sender), msg.sender);
    }

    function emergencyClaimAndMigrate(uint256 vaultId) external {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        RewardDistributionTokenUpgradeable oldDist = _oldRewardDistributionTokenAddr(pool);
        require(isContract(address(oldDist)), "Not a pool");
        RewardDistributionTokenUpgradeable newDist = _rewardDistributionTokenAddr(pool);
        if (!isContract(address(newDist))) {
            address deployedDist = _deployDividendToken(pool);
            require(deployedDist == address(newDist), "Not deploying proper distro");
            emit PoolUpdated(vaultId, deployedDist);
        }
        uint256 bal = oldDist.balanceOf(msg.sender);
        require(bal > 0, "Nothing to migrate");
        oldDist.withdrawReward(msg.sender);
        oldDist.burnFrom(msg.sender, bal);
        newDist.mint(msg.sender, msg.sender, bal);
    }

    function emergencyMigrate(uint256 vaultId) external {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        RewardDistributionTokenUpgradeable oldDist = _oldRewardDistributionTokenAddr(pool);
        require(isContract(address(oldDist)), "Not a pool");
        RewardDistributionTokenUpgradeable newDist = _rewardDistributionTokenAddr(pool);
        if (!isContract(address(newDist))) {
            address deployedDist = _deployDividendToken(pool);
            require(deployedDist == address(newDist), "Not deploying proper distro");
            emit PoolUpdated(vaultId, deployedDist);
        }
        uint256 bal = oldDist.balanceOf(msg.sender);
        require(bal > 0, "Nothing to migrate");
        oldDist.burnFrom(msg.sender, bal);
        newDist.mint(msg.sender, msg.sender, bal);
    }

    function withdraw(uint256 vaultId, uint256 amount) external {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        _withdraw(pool, amount, msg.sender);
    }

    function claimRewards(uint256 vaultId) external {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        _claimRewards(pool, msg.sender);
    }

   function rewardDistributionToken(uint256 vaultId) external view returns (RewardDistributionTokenUpgradeable) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        if (pool.stakingToken == address(0)) {
            return RewardDistributionTokenUpgradeable(address(0));
        }
        return _oldRewardDistributionTokenAddr(pool);
    }

    function newRewardDistributionToken(uint256 vaultId) external view returns (RewardDistributionTokenUpgradeable) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        if (pool.stakingToken == address(0)) {
            return RewardDistributionTokenUpgradeable(address(0));
        }
        return _rewardDistributionTokenAddr(pool);
    }

    function oldRewardDistributionToken(uint256 vaultId) external view returns (address) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        if (pool.stakingToken == address(0)) {
            return address(0);
        }
        return address(_oldRewardDistributionTokenAddr(pool));
    }

    function rewardDistributionTokenAddr(address stakingToken, address rewardToken) public view returns (address) {
        StakingPool memory pool = StakingPool(stakingToken, rewardToken);
        return address(_rewardDistributionTokenAddr(pool));
    }

    function balanceOf(uint256 vaultId, address addr) public view returns (uint256) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        RewardDistributionTokenUpgradeable dist = _rewardDistributionTokenAddr(pool);
        require(isContract(address(dist)), "Not a pool");
        return dist.balanceOf(addr);
    }

    function oldBalanceOf(uint256 vaultId, address addr) public view returns (uint256) {
        StakingPool memory pool = vaultStakingInfo[vaultId];
        RewardDistributionTokenUpgradeable dist = _oldRewardDistributionTokenAddr(pool);
        require(isContract(address(dist)), "Not a pool");
        return dist.balanceOf(addr);
    }

    function _deployDividendToken(StakingPool memory pool) internal returns (address) {
        // Changed to use new nonces.
        bytes32 salt = keccak256(abi.encodePacked(pool.stakingToken, pool.rewardToken, uint256(1)));
        address rewardDistToken = ClonesUpgradeable.cloneDeterministic(address(rewardDistTokenImpl), salt);
        string memory name = stakingTokenProvider.nameForStakingToken(pool.rewardToken);
        RewardDistributionTokenUpgradeable(rewardDistToken).__RewardDistributionToken_init(IERC20Upgradeable(pool.rewardToken), name, name);
        return rewardDistToken;
    }

    function _deposit(StakingPool memory pool, uint256 amount) internal {
        require(pool.stakingToken != address(0), "LPStaking: Nonexistent pool");
        IERC20Upgradeable(pool.stakingToken).safeTransferFrom(msg.sender, address(this), amount);
        _rewardDistributionTokenAddr(pool).mint(msg.sender, msg.sender, amount);
    }

    function _claimRewards(StakingPool memory pool, address account) internal {
        require(pool.stakingToken != address(0), "LPStaking: Nonexistent pool");
        _rewardDistributionTokenAddr(pool).withdrawReward(account);
    }

    function _withdraw(StakingPool memory pool, uint256 amount, address account) internal {
        require(pool.stakingToken != address(0), "LPStaking: Nonexistent pool");
        _rewardDistributionTokenAddr(pool).burnFrom(account, amount);
        IERC20Upgradeable(pool.stakingToken).safeTransfer(account, amount);
    }

    // Note: this function does not guarantee the token is deployed, we leave that check to elsewhere to save gas.
    function _oldRewardDistributionTokenAddr(StakingPool memory pool) public view returns (RewardDistributionTokenUpgradeable) {
        bytes32 salt = keccak256(abi.encodePacked(pool.stakingToken, pool.rewardToken));
        address tokenAddr = ClonesUpgradeable.predictDeterministicAddress(address(rewardDistTokenImpl), salt);
        return RewardDistributionTokenUpgradeable(tokenAddr);
    }

    // Note: this function does not guarantee the token is deployed, we leave that check to elsewhere to save gas.
    function _rewardDistributionTokenAddr(StakingPool memory pool) public view returns (RewardDistributionTokenUpgradeable) {
        bytes32 salt = keccak256(abi.encodePacked(pool.stakingToken, pool.rewardToken, uint256(1) /* small nonce to change tokens */));
        address tokenAddr = ClonesUpgradeable.predictDeterministicAddress(address(rewardDistTokenImpl), salt);
        return RewardDistributionTokenUpgradeable(tokenAddr);
    }

    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}