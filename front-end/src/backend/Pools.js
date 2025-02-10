import { ConsoleSqlOutlined } from "@ant-design/icons";
import { aptos } from "../App.js";
import { moduleAddress } from "../App.js";
import { useWallet, InputTransactionData, InputViewFunctionData } from "@aptos-labs/wallet-adapter-react";
import { Account } from "@aptos-labs/ts-sdk";
import { responsiveFontSizes } from "@mui/material";




export async function addLiquidity(pool, asset_amount, signAndSubmitTransaction) {
    const payload = {  
        function: `${moduleAddress}::Multi_Token_Pool::get_pool_amount_out`,
        functionArguments: [Number(pool.pool_id), Number(asset_amount[0]), pool.assets[0].asset.name, pool.assets[0].asset.symbol]
        
    }

    let result;
    try {
        result = (await aptos.view({ payload }))[0]; 
        console.log(result);
    } catch (error) {
        console.log(error);
        return;
    }

    const join_pool_payload = {
        data: {
            function: `${moduleAddress}::Multi_Token_Pool::join_pool`,
            functionArguments: [pool.pool_id, result, asset_amount.map((amount) => Number(1000000000000))]
        }
    }

    try {
        const response = signAndSubmitTransaction(join_pool_payload);
        return response;
    }
    catch (error) {
        console.log(error);
        return;
    }
}

export async function getTokenAmountInList(value, pool){
    console.log(pool.assets[0].asset.name,  pool.assets[0].asset.symbol, value, moduleAddress);
    const payload = {  
        function: `${moduleAddress}::Multi_Token_Pool::get_token_amount_in_list`,
        functionArguments: [pool.pool_id, value, pool.assets[0].asset.name, pool.assets[0].asset.symbol]      
    }

    try {
        const response = await  aptos.view({ payload });
        const result = response[0]; 
        console.log("return result", result);
        return result;
    }catch(error){
        console.log("Oops ", error);
        return;
    }
}

export async function createPool(assets, assetAmount, assetWeights, signAndSubmitTransaction) {
    const pool_account = Account.generate();
    console.log(pool_account.accountAddress.toString());
    
    const create_pool_payload = {
        data: {
            function: `${moduleAddress}::Multi_Token_Pool::create_pool`,
            functionArguments: [pool_account.accountAddress.toString(), 0]
        }
    };


    
    try {
        const response = await signAndSubmitTransaction(create_pool_payload);
        await aptos.waitForTransaction({transactionHash:response.hash});
    } catch(error){
        console.log(error);
        return;
    }
    console.log("============CREATE POOL SUCCESS============");

    for(let i = 0; i < assets.length; i++){
        const bind_payload = {
            data: {
                function: `${moduleAddress}::Multi_Token_Pool::bind`,
                functionArguments: [2, assetAmount[i], assetWeights[i], assets[i].name, assets[i].symbol]
            }
        };

        console.log(`============BINDING ASSET: ${assets[i].name}============`);

        try {
            const response = await signAndSubmitTransaction(bind_payload);
            await aptos.waitForTransaction({transactionHash:response.hash});
        } catch(error){
            console.log(error);
            return;
        }
        console.log(`============BINDING ASSET: ${assets[i].name}============`);
    }

    const finalize_payload = {
        data: {
            function: `${moduleAddress}::Multi_Token_Pool::finalize`,
            functionArguments: [2]
        }
    };

    try {
        const response = signAndSubmitTransaction(finalize_payload);
        return response;
        // await aptos.waitForTransaction({transactionHash:response.hash});
    } catch(error) {
        console.log(error);
        return;
    }

    console.log("============FINALIZE SUCCESS============");
}