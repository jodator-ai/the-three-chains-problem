import { ETH_ADDRESS } from '@matterlabs/zksync-js/core';
import { createViemClient, createViemSdk } from '@matterlabs/zksync-js/viem';
import { createPublicClient, createWalletClient, http, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { anvil } from 'viem/chains';

const DEPLOYER_PK = (process.env.PRIVATE_KEY ||
    '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80') as `0x${string}`;
const L1_RPC = process.env.L1_RPC_URL || 'http://localhost:5010';
const L2_RPC = process.env.L2_RPC_URL || 'http://localhost:5050';
const BRIDGE_AMOUNT = parseEther('100');

async function main() {
    const account = privateKeyToAccount(DEPLOYER_PK);

    // Check if deployer already has funds on L2
    const l2 = createPublicClient({ transport: http(L2_RPC) });
    const balance = await l2.getBalance({ address: account.address });

    if (balance < BRIDGE_AMOUNT / 2n) {
        console.log('Bridging ETH from L1 to L2...');

        const l1 = createPublicClient({ chain: anvil, transport: http(L1_RPC) });
        const l1Wallet = createWalletClient({
            account,
            chain: anvil,
            transport: http(L1_RPC)
        });

        const client = createViemClient({ l1, l2, l1Wallet });
        const sdk = createViemSdk(client);

        const handle = await sdk.deposits.create({
            token: ETH_ADDRESS,
            amount: BRIDGE_AMOUNT,
            to: account.address
        });

        await sdk.deposits.wait(handle, { for: 'l2' });
        console.log('Bridge complete');
    } else {
        console.log('Deployer already funded on L2');
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
