module pool_addr::Pool_Test {
    use std::signer;
    use std::vector;
    use std::debug::print;
    use std::aptos_account;
    use std::account;
    use std::option;
    use std::string::{Self, String};
    use std::simple_map::{Self, SimpleMap};
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use pool_addr::Multi_Token_Pool;
    use lst_addr::Liquid_Staking_Token;

    const ERR_TEST: u64 = 0;

    #[test_only]
    public fun create_token_test(
        sender: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        initial_supply: u64,
    ): Object<Metadata> {
        Liquid_Staking_Token::create_fa(signer::address_of(sender), name, symbol, decimals, icon_uri, project_uri);
        Liquid_Staking_Token::mint(sender, signer::address_of(sender), initial_supply, name, symbol);
        let asset = Liquid_Staking_Token::get_metadata(name, symbol);
        asset 
    }

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_bind_and_unbind(admin: signer, creator: signer, user1: signer, user2: signer) {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init_module_for_test(&creator);
        Multi_Token_Pool::init_module_for_test(&admin);
        let pool_1_address = @0x101;
        Multi_Token_Pool::create_pool(&user1, pool_1_address, 1000);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500000000,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500000000,
        );

        Multi_Token_Pool::bind(&user1, 0, 100000000, 50000000, usdt_name, usdt_symbol);
        Multi_Token_Pool::bind(&user1, 0, 150000000, 50000000, eth_name, eth_symbol);
        let (
            bound,
            index, 
            denorm,
            balance,
            name,
            symbol,
        ) = Multi_Token_Pool::get_token_record(0, 0);
        assert!(bound == true, ERR_TEST);
        assert!(index == 0, ERR_TEST);
        assert!(denorm == 50000000, ERR_TEST);
        assert!(balance == 100000000, ERR_TEST);
        let (total_weight, swap_fee, is_finalized, total_supply, pool_address) = Multi_Token_Pool::get_pool_info(0);
        assert!(total_weight == 100000000, ERR_TEST);

        let user1_usdt_balance = Multi_Token_Pool::get_balance(user1_addr, usdt_name, usdt_symbol);
        assert!(user1_usdt_balance == 400000000, ERR_TEST);
        let user1_eth_balance = Multi_Token_Pool::get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 350000000, ERR_TEST);

        let pool_usdt_balance = Multi_Token_Pool::get_balance(pool_1_address, usdt_name, usdt_symbol);
        assert!(pool_usdt_balance == 100000000, ERR_TEST);
        let pool_eth_balance = Multi_Token_Pool::get_balance(pool_1_address, eth_name, eth_symbol);
        assert!(pool_eth_balance == 150000000, ERR_TEST);

        // // unbind
        Multi_Token_Pool::unbind(&user1, 0, eth_name, eth_symbol);
        let (
            bound,
            index, 
            denorm,
            balance,
            name,
            symbol,
        ) = Multi_Token_Pool::get_token_record(0, 0);
        let (total_weight, swap_fee, is_finalized, total_supply, pool_address) = Multi_Token_Pool::get_pool_info(0);
        assert!(total_weight == 50000000, ERR_TEST);

        let user1_eth_balance = Multi_Token_Pool::get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 500000000, ERR_TEST);
        let pool_eth_balance = Multi_Token_Pool::get_balance(@pool_addr, eth_name, eth_symbol);
        assert!(pool_eth_balance == 0, ERR_TEST);

        // creator another pool
        let pool_2_address = @0x102;
        Multi_Token_Pool::create_pool(&user1, pool_2_address, 1000);
        Multi_Token_Pool::bind(&user1, 1, 200000000, 50000000, eth_name, eth_symbol);
        let user1_eth_balance = Multi_Token_Pool::get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 300000000, ERR_TEST);
        let pool_eth_balance = Multi_Token_Pool::get_balance(pool_2_address, eth_name, eth_symbol);
        assert!(pool_eth_balance == 200000000, ERR_TEST);
    }

     #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_swap_exact_amount_in(admin: signer, creator: signer, user1: signer, user2: signer) {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init_module_for_test(&creator);
        Multi_Token_Pool::init_module_for_test(&admin);
        let pool_1_address = @0x101;
        Multi_Token_Pool::create_pool(&user1, pool_1_address, 1000);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Multi_Token_Pool::bind(&user1, 0, 100000000, 50000000, usdt_name, usdt_symbol);
        Multi_Token_Pool::bind(&user1, 0, 150000000, 50000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, eth_name, eth_symbol);
        let (
            bound,
            index, 
            denorm,
            balance,
            name,
            symbol,
        ) = Multi_Token_Pool::get_token_record(0, 0);
        Multi_Token_Pool::finalize(&user1, 0);
        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        let (token_amount_out, spot_price_after) = Multi_Token_Pool::get_swap_exact_amount_in(
            user2_addr,
            0,
            usdt_name,
            usdt_symbol,
            10000000,
            eth_name,
            eth_symbol,
            0,
            1000000
        );
        // print(&token_amount_out);
        Multi_Token_Pool::swap(
            &user2,
            0,
            usdt_name,
            usdt_symbol,
            10000000,
            eth_name,
            eth_symbol,
            token_amount_out,
        );
        
        let user2_usdt_balance = Multi_Token_Pool::get_balance(user2_addr, usdt_name, usdt_symbol);
        assert!(user2_usdt_balance == 500000000 - 10000000, ERR_TEST);
        let user2_eth_balance = Multi_Token_Pool::get_balance(user2_addr, eth_name, eth_symbol);
        assert!(user2_eth_balance == 500000000 + token_amount_out, ERR_TEST);
    } 

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    fun test_join_pool_and_exit_pool(admin: signer, creator: signer, user1: signer, user2: signer) {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init_module_for_test(&creator);
        Multi_Token_Pool::init_module_for_test(&admin);
        let pool_1_address = @0x101;
        Multi_Token_Pool::create_pool(&user1, pool_1_address, 1000);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Multi_Token_Pool::bind(&user1, 0, 100000000, 50000000, usdt_name, usdt_symbol);
        Multi_Token_Pool::bind(&user1, 0, 150000000, 50000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, eth_name, eth_symbol);

        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        Multi_Token_Pool::finalize(&user1, 0);
        Multi_Token_Pool::join_pool(&user1, 0, 10000000, max_amounts_in);
        
        // sender hold 10% of pool share, so sender can claim 10 LPT and must deposit 10 Token 1 and 20 Token 2
        let user1_lpt_balance = Multi_Token_Pool::get_balance(user1_addr, lpt_name, lpt_symbol);
        assert!(user1_lpt_balance == 10000000, ERR_TEST);
        let user1_usdt_balance = Multi_Token_Pool::get_balance(user1_addr, usdt_name, usdt_symbol);
        // print(&user1_usdt_balance);
        assert!(user1_usdt_balance == 390000000, ERR_TEST);
        let user1_eth_balance = Multi_Token_Pool::get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 335000000, ERR_TEST);

        // let pool_balance = primary_fungible_store::balance(sender_addr, asset);
        let min_amounts_out: vector<u64> = vector[0, 0];
        Multi_Token_Pool::exit_pool(&user1, 0, 10000000, min_amounts_out);
        let user1_lpt_balance = Multi_Token_Pool::get_balance(user1_addr, lpt_name, lpt_symbol);
        assert!(user1_lpt_balance == 0, ERR_TEST);
        let user1_usdt_balance = Multi_Token_Pool::get_balance(user1_addr, usdt_name, usdt_symbol);
        // print(&user1_usdt_balance);
        // assert!(user1_usdt_balance == 400000000, ERR_TEST);
        let user1_eth_balance = Multi_Token_Pool::get_balance(user1_addr, eth_name, eth_symbol);
        // print(&user1_eth_balance);
        // assert!(user1_eth_balance == 350000000, ERR_TEST);
    
    }

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_join_swap_pool_amount_out(admin: signer, creator: signer, user1: signer, user2: signer) {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init_module_for_test(&creator);
        Multi_Token_Pool::init_module_for_test(&admin);
        let pool_1_address = @0x101;
        Multi_Token_Pool::create_pool(&user1, pool_1_address, 1000);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Multi_Token_Pool::bind(&user1, 0, 100000000, 50000000, usdt_name, usdt_symbol);
        Multi_Token_Pool::bind(&user1, 0, 150000000, 50000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, eth_name, eth_symbol);
        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        Multi_Token_Pool::finalize(&admin, 0);
        let token_amount_in = Multi_Token_Pool::get_join_swap_pool_amount_out(
            user2_addr,
            0,
            usdt_name,
            usdt_symbol,
            10000000,
            500000000,
        );
        // print(&token_amount_in);
        Multi_Token_Pool::join_swap(
            &user2,
            0,
            usdt_name,
            usdt_symbol,
            token_amount_in,
            10000000,
        );
        let user2_lpt_balance = Multi_Token_Pool::get_balance(user2_addr, lpt_name, lpt_symbol);
        assert!(user2_lpt_balance == 10000000, ERR_TEST);
        let user2_usdt_balance = Multi_Token_Pool::get_balance(user2_addr, usdt_name, usdt_symbol);
        assert!(user2_usdt_balance == 500000000 - token_amount_in, ERR_TEST);

        let token_amount_out = Multi_Token_Pool::get_exit_swap_pool_amount_in(
            user2_addr,
            0,
            usdt_name,
            usdt_symbol,
            10000000,
            0,
        );
        // print(&token_amount_out);
        Multi_Token_Pool::exit_swap(
            &user2,
            0,
            usdt_name,
            usdt_symbol,
            10000000,
            token_amount_out,
        );
        let user2_lpt_balance = Multi_Token_Pool::get_balance(user2_addr, lpt_name, lpt_symbol);
        assert!(user2_lpt_balance == 0, ERR_TEST);
        let user2_usdt_balance = Multi_Token_Pool::get_balance(user2_addr, usdt_name, usdt_symbol);
        // print(&user2_usdt_balance);
    } 

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun get_token_amount_in_list(admin: signer, creator: signer, user1: signer, user2: signer) {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init_module_for_test(&creator);
        Multi_Token_Pool::init_module_for_test(&admin);
        let pool_1_address = @0x101;
        Multi_Token_Pool::create_pool(&user1, pool_1_address, 1000);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Multi_Token_Pool::bind(&user1, 0, 100000000, 50000000, usdt_name, usdt_symbol);
        Multi_Token_Pool::bind(&user1, 0, 150000000, 50000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&user1, user1_addr, user2_addr, 500000000, eth_name, eth_symbol);
        Multi_Token_Pool::finalize(&user1, 0);
        let pool_amount_out = Multi_Token_Pool::get_pool_amount_out(0, 50000000, eth_name, eth_symbol);
        // print(&pool_amount_out);

        let token_amount_in_list = Multi_Token_Pool::get_token_amount_in_list(0, 50000000, eth_name, eth_symbol);
        let length = vector::length(&token_amount_in_list);
        let i = 0;
        while(i < length) {
            let token_amount_in = *vector::borrow(&token_amount_in_list, (i as u64));
            print(&token_amount_in);
            i = i + 1;
        }

    } 

}