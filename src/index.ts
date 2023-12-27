
import { main } from '../scripts/runBot';
import * as dotenv from "dotenv";

dotenv.config();
let btcPrice = 0;
let ethPrice = 0;


async function runArbitrages(liquidateBull: Boolean) {
    await main();

    return true;
}

async function checkBTCAndETHPrice(): Promise<string> {
    let url = `https://api.coingecko.com/api/v3/simple/price?ids=bitcoin%2Cethereum&vs_currencies=usd`;
    let headers = {
        'accept': 'application/json',
        'x_cg_pro_api_key': process.env.COINGECKO_API_KEY || ''
    }

    const resp = await fetch(url, { headers: headers });
    const data: any = await resp.json();
    console
    const newBtcPrice = data.bitcoin.usd;
    const newEthPrice = data.ethereum.usd;
    console.log("BTC price: ", btcPrice, newBtcPrice);

    if (newBtcPrice > btcPrice * 1.015) {
        console.log("BTC price got up more than 1.5%: ", btcPrice, newBtcPrice);
        btcPrice = newBtcPrice;
        ethPrice = newEthPrice;
        return 'up';
    }
    if (newBtcPrice < btcPrice * 0.985) {
        console.log("BTC price got down more than 1.5 %: ", btcPrice, newBtcPrice);
        btcPrice = newBtcPrice;
        ethPrice = newEthPrice;
        return 'down';
    }
    if (newEthPrice > ethPrice * 1.015) {
        console.log("ETH price got up more than 1.5%: ", ethPrice, newEthPrice);
        btcPrice = newBtcPrice;
        ethPrice = newEthPrice;
        return 'up';
    }
    if (newEthPrice < ethPrice * 0.985) {
        console.log("ETH price got down more than 1.5%: ", ethPrice, newEthPrice);
        btcPrice = newBtcPrice;
        ethPrice = newEthPrice;
        return 'down';
    }
    return 'stable';
}





async function myMain() {

    const checkPrice = await checkBTCAndETHPrice();

    if (checkPrice === 'up') {
        await runArbitrages(true).catch((e) => {
            console.log("Error: ", e);
        });
        // arbitrage ran : so we rerun the main function
        myMain();
        return;
    } else if (checkPrice === 'down') {
        await runArbitrages(false).catch((e) => {
            console.log("Error: ", e);

        });
        // arbitrage ran : so we rerun the main function
        myMain();
        return;
    }


    console.log("Price is stable");
    // price was stable (arbitrage did'nt run) : so we wait 1 hour before checking again
    setTimeout(() => {
        main();
    }, 60 * 60 * 1000);


}
// run main


myMain().catch((e) => {
    console.log("Error: ", e);
});
process.on('uncaughtException', function (err) {
    console.log(err);
}); 