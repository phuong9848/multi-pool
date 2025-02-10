module pool_addr::Multi_Token_Pool {
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
    use pool_addr::Pool_Math;
    use lst_addr::Liquid_Staking_Token;

    const ERR_LIMIT_IN:u64 = 0;
    const ERR_TEST: u64 = 101;
    const ERR_BAD_LIMIT_PRICE:u64 = 1;
    const ERR_LIMIT_OUT:u64 = 2;
    const ERR_MATH_APPROX:u64 = 3;
    const ERR_LIMIT_PRICE:u64 = 4;

    const INIT_POOL_SUPPLY: u256 = 100 * 1000000;
    const BONE: u256 = 1000000;
    const MIN_FEE: u256 = 1000;

    struct PoolList has key {
        pool_list: vector<PoolInfo>,
    }

    struct PoolInfo has key, store, copy, drop {
        pool_id: u64,
        pool_address: address,
        total_weight: u256,
        swap_fee: u256,
        is_finalized: bool,
        total_supply: u256,
        token_list: vector<address>,
        token_record: SimpleMap<address, Record>,
    }

    struct Record has key, store, copy, drop {
        bound: bool,
        index: u64, 
        denorm: u256,
        balance: u256,
        name: String,
        symbol: String,
    }

    fun init_module(sender: &signer) {
        let pool_list = PoolList {
            pool_list: vector::empty(),
        };
        move_to(sender, pool_list);

        let name = string::utf8(b"LP Token");
        let symbol = string::utf8(b"LPT");
        let decimals = 6;
        let icon_uri = string::utf8(b"http://example.com/favicon.ico");
        let project_uri = string::utf8(b"http://example.com");
        Liquid_Staking_Token::create_fa(@lst_addr, name, symbol, decimals, icon_uri, project_uri);
    }


    // =============================== Entry Function =====================================

    public entry fun create_pool(sender: &signer, pool_address: address, swap_fee: u256) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);

        let pool_info = PoolInfo {
            pool_id: vector::length(&pool_list.pool_list),
            pool_address: pool_address,
            total_weight: 0,
            swap_fee: swap_fee,
            is_finalized: false,
            total_supply: 0,
            token_list: vector::empty(),
            token_record: simple_map::create(),
        };
        vector::push_back(&mut pool_list.pool_list, pool_info);
    } 

    // mint and push LP Token to owner
    public entry fun finalize(sender: &signer, pool_id: u64) acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        pool.is_finalized = true;
        mint_and_push_pool_share(sender, pool.pool_address, INIT_POOL_SUPPLY);
        pool.total_supply = pool.total_supply + INIT_POOL_SUPPLY;
    }

    public entry fun bind(sender: &signer, pool_id: u64, balance: u256, denorm: u256, name: String, symbol: String) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let record = Record {
            bound: true,
            index: vector::length(token_list),
            denorm: 0, // denorm and balance will be validated
            balance: 0, //  and set by rebind
            name: name,
            symbol: symbol,
        };

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        simple_map::add(token_record, token_address, record);
        vector::push_back(token_list, token_address);
        // pool.token_record = token_record;
        // pool.token_list = token_list;
        rebind(sender, balance, pool_id, denorm, name, symbol);
    }

    public entry fun rebind(sender: &signer, balance: u256, pool_id: u64, denorm: u256, name: String, symbol: String) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(token_record, &token_address);
        let old_weight = record.denorm;
        if(old_weight < denorm) {
            pool.total_weight = pool.total_weight + denorm - old_weight;
        } else {
            pool.total_weight = pool.total_weight + old_weight - denorm;
        };
        record.denorm = denorm;

        // adjust the balance record and actual token balance
        let old_balance = record.balance;
        record.balance = balance;
        if(balance > old_balance) {
            pull_underlying(sender, pool.pool_address, balance - old_balance, name, symbol);
        } else {
            pull_underlying(sender, pool.pool_address, old_balance - balance, name, symbol);
        }

    }

    public entry fun unbind(sender: &signer, pool_id: u64, name: String, symbol: String) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);

        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(token_record, &token_address);
        let token_balance = record.balance;
        pool.total_weight = pool.total_weight - record.denorm;

        // swap the token-to-unbind with the last token
        // then delete the last token
        let index = record.index;
        let last = vector::length(token_list) - 1;
        let address_last = {
            let addr = *vector::borrow(token_list, last);
            addr
        };
        // print(&token_address);
        // print(&address_index);
        // let i = 0;
        // while (i <= last) {
        //     let addr = *vector::borrow(&token_list.token_list, (i as u64));
        //     print(&addr);
        //     i = i + 1;
        // };
        vector::swap(token_list, index, last);
        record.bound = false;
        record.balance = 0;
        record.index = 0;
        record.denorm = 0;
        record.name = string::utf8(b"");
        record.symbol = string::utf8(b"");
        
        simple_map::remove<address, Record>(token_record, &token_address);
        if(index != last) {
            let record_last = simple_map::borrow_mut<address, Record>(token_record, &address_last);
            record_last.index = index;
        };
        vector::pop_back(token_list);
        // pool.token_list = token_list;
        // pool.token_record = token_record;
        push_underlying(sender, pool.pool_address, token_balance, name, symbol);
    }

    public entry fun swap (
        sender: &signer,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u256,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u256,
    ) acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);
        pull_underlying(sender, pool.pool_address, token_amount_in, token_in_name, token_in_symbol);
        {
            let token_in_record = simple_map::borrow_mut(token_record, &token_in_address);
            token_in_record.balance = token_in_record.balance + token_amount_in;
        };
        push_underlying(sender, pool.pool_address, token_amount_out, token_out_name, token_out_symbol);
        {
            let token_out_record = simple_map::borrow_mut(token_record, &token_out_address);
            token_out_record.balance = token_out_record.balance - token_amount_out;
        };

        
        
    }

    public entry fun join_swap (
        sender: &signer,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u256,
        pool_amount_out: u256,
    ) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
        pool.total_supply = pool.total_supply + pool_amount_out;
        pull_underlying(sender, pool.pool_address, token_amount_in, token_in_name, token_in_symbol,);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record = simple_map::borrow_mut(token_record, &token_in_address);
        let token_in_record = simple_map::borrow_mut(token_record, &token_in_address);
        token_in_record.balance = token_in_record.balance + token_amount_in;
    }

    public entry fun exit_swap(
        sender: &signer,
        pool_id: u64,
        token_out_name: String,
        token_out_symbol: String,
        pool_amount_in: u256,
        token_amount_out: u256,
    ) acquires PoolList{
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);
        pull_pool_share(sender, pool.pool_address, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool.pool_address, pool_amount_in);
        pool.total_supply = pool.total_supply - pool_amount_in;
        push_underlying(sender, pool.pool_address, token_amount_out, token_out_name, token_out_symbol);
        {
            let token_out_record = simple_map::borrow_mut(token_record, &token_out_address);
            token_out_record.balance = token_out_record.balance - token_amount_out;
        };
    }

    public entry fun join_pool(sender: &signer, pool_id: u64, pool_amount_out: u256, max_amounts_in: vector<u256>) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        // print(&pool_amount_out);
        // print(&pool_total);
        // print(&ratio);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_list = &mut pool.token_list;
        let token_record = &mut pool.token_record;
        let ratio = Pool_Math::div(pool_amount_out, pool.total_supply);

        let token_list_length = vector::length(token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(token_record, token_address);
            let max_amount_in = vector::borrow(&max_amounts_in, (i as u64));
            let name = record.name;
            let symbol = record.symbol;
            // Amount In to deposit
            let token_amount_in = Pool_Math::mul(ratio, record.balance);
            assert!(token_amount_in <= *max_amount_in, ERR_LIMIT_IN);

            record.balance = record.balance + token_amount_in;
            pull_underlying(sender, pool.pool_address, token_amount_in, name, symbol);
            i = i + 1;
        };
        
        // todo: mint and deposit LP Token to sender
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
        pool.total_supply = pool.total_supply + pool_amount_out;
    }

    public entry fun exit_pool(sender: &signer, pool_id: u64, pool_amount_in: u256, min_amounts_out: vector<u256>) acquires PoolList {
        let sender_addr = signer::address_of(sender);
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_list = &mut pool.token_list;
        let token_record = &mut pool.token_record;
        let total_supply = pool.total_supply;
        let ratio = Pool_Math::div(pool_amount_in, total_supply);
        // print(&pool_amount_in);
        // print(&pool_total);
        // print(&ratio);
        pull_pool_share(sender, pool.pool_address, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool.pool_address, pool_amount_in);
        pool.total_supply = pool.total_supply - pool_amount_in;
        let token_list_length = vector::length(token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(token_record, token_address);
            let min_amount_out = vector::borrow(&min_amounts_out, (i as u64));
            let name = record.name;
            let symbol = record.symbol;
            let token_amount_out = Pool_Math::mul(ratio, record.balance);
            // print(&ratio);
            // print(&record.balance);
            // print(&token_amount_out);
            record.balance = record.balance - token_amount_out;
            push_underlying(sender, pool.pool_address, token_amount_out, name, symbol);
            i = i + 1;
        }
    }

    // // ========================================= View Function ==========================================

    #[view]
    public fun get_pool_info(pool_id: u64): (u256, u256, bool, u256, address) acquires PoolList {
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        (pool.total_weight, pool.swap_fee, pool.is_finalized, pool.total_supply, pool.pool_address)
    }

    #[view]
    public fun get_token_record(pool_id: u64, token_index: u64): (bool, u64, u256, u256, String, String) acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let token_address = vector::borrow(&token_list, token_index);
        let record = simple_map::borrow<address, Record>(&token_record, token_address);
        (
            record.bound,
            record.index, 
            record.denorm,
            record.balance,
            record.name, 
            record.symbol,
        )
    }

    #[view]
    public fun get_swap_exact_amount_in(
        sender_addr: address,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u256,
        token_out_name: String,
        token_out_symbol: String,
        min_amount_out: u256,
        max_price: u256,
    ): (u256, u256) acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);    
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        
        let spot_price_before = Pool_Math::calc_spot_price (
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);

        let token_amount_out = Pool_Math::calc_out_given_in(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            token_amount_in,
            pool.swap_fee,
        );
        assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
        {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            record_token_in.balance = record_token_in.balance - token_amount_in;
        };
       
        {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            record_token_out.balance = record_token_out.balance + token_amount_out;
        };

        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_after = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_out, spot_price_after)
    }

    #[view]
    public fun get_swap_exact_amount_out (
        sender_addr: address,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        max_amount_in: u256,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u256,
        max_price: u256,
    ): (u256, u256) acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);    
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_before = Pool_Math::calc_spot_price (
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);
        let token_amount_in = Pool_Math::calc_in_given_out(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            token_amount_out,
            pool.swap_fee,
        );
        assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);
        {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            record_token_in.balance = record_token_in.balance - token_amount_in;
        };
        {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            record_token_out.balance = record_token_out.balance + token_amount_out;
        };
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_after = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_in, spot_price_after)
    }

    #[view]
    public fun get_join_swap_extern_amount_in (
        sender_addr: address,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String, 
        token_amount_in: u256,
        min_pool_amount_out: u256,
    ): u256 acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
        let total_supply_lpt = pool.total_supply;
        let pool_amount_out = Pool_Math::calc_pool_out_given_single_in(
            record_token_in.balance,
            record_token_in.denorm,
            total_supply_lpt,
            pool.total_weight,
            token_amount_in,
            pool.swap_fee,
        );
        // print(&pool_amount_out);
        assert!(pool_amount_out >= min_pool_amount_out, ERR_LIMIT_OUT);
        record_token_in.balance = record_token_in.balance + token_amount_in;
        pool_amount_out
    }

    #[view]
    public fun get_join_swap_pool_amount_out (
        sender_addr: address,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        pool_amount_out: u256,
        max_amount_in: u256,
    ): u256 acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
        let total_supply_lpt = pool.total_supply;
        let token_amount_in = Pool_Math::calc_single_in_given_pool_out (
            record_token_in.balance,
            record_token_in.denorm,
            total_supply_lpt,
            pool.total_weight,
            pool_amount_out,
            pool.swap_fee,
        );
        assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);
        record_token_in.balance = record_token_in.balance + token_amount_in;
        token_amount_in
    }

    #[view] 
    public fun get_exit_swap_pool_amount_in (
        sender_addr: address,
        pool_id: u64,
        token_in_name: String,
        token_in_symbol: String,
        pool_amount_in: u256,
        min_amount_out: u256,
    ): u256 acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
        let total_supply_lpt = pool.total_supply;
        let token_amount_out = Pool_Math::calc_single_out_given_pool_in (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply_lpt,
            pool.total_weight,
            pool_amount_in,
            pool.swap_fee
        );
        assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
        record_token_out.balance = record_token_out.balance - token_amount_out;
        token_amount_out
    }

    #[view]
    public fun get_exit_swap_extern_amount_out(
        sender_addr: address,
        pool_id: u64,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u256,
        max_pool_amount_in: u256,
    ): u256 acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_record = &mut pool.token_record;
        let token_list = &mut pool.token_list;
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);
        let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
        let total_supply_lpt = pool.total_supply;
        let pool_amount_in = Pool_Math::calc_pool_in_given_single_out (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply_lpt,
            pool.total_weight,
            token_amount_out,
            pool.swap_fee,
        );
        assert!(pool_amount_in <= max_pool_amount_in, ERR_LIMIT_IN);
        record_token_out.balance = record_token_out.balance -  token_amount_out;
        pool_amount_in
    }

    #[view]
    public fun get_pool_amount_out(pool_id: u64, token_amount_in: u256, name: String, symbol: String): u256 acquires PoolList {
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        let record = simple_map::borrow(&token_record, &token_address);
        let ratio = Pool_Math::div(token_amount_in, record.balance);
        let pool_amount_out = Pool_Math::mul(ratio, pool.total_supply);
        pool_amount_out
    }

    #[view]
    public fun get_token_amount_in_list(pool_id: u64, token_amount_in: u256, name: String, symbol: String): vector<u256> acquires PoolList {
        let pool_amount_out = get_pool_amount_out(pool_id, token_amount_in, name, symbol);
        let token_amount_in_list = vector::empty<u256>();

        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;

        let token_length = vector::length(&token_list);
        let i = 0;
        while(i < token_length) {
            let ratio = Pool_Math::div(pool_amount_out, pool.total_supply);
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_amount_in = Pool_Math::mul(ratio, record.balance);
            vector::push_back(&mut token_amount_in_list, token_amount_in);
            // print(&pool_amount_out);
            // print(&pool.total_supply);
            // print(&ratio);
            // print(&record.balance);
            // print(&token_amount_in);
            i = i + 1;
        };
        token_amount_in_list
    }

    #[view]
    public fun get_balance(sender_addr: address, name: String, symbol: String): u256 {
        Liquid_Staking_Token::get_balance(sender_addr, name, symbol)
    }

    #[view]
    public fun get_num_pools(): u64 acquires PoolList {
        let pool_list = borrow_global<PoolList>(@pool_addr);
        vector::length(&pool_list.pool_list)
    }

    #[view]
    public fun get_num_tokens(pool_id: u64): u64 acquires PoolList {
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        vector::length(&pool.token_list)
    }

    #[view]
    public fun get_token_name_list(pool_id: u64): vector<String> acquires PoolList {
        let token_name_list = vector::empty<String>();
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let num_tokens = vector::length(&token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_name = record.name;
            vector::push_back(&mut token_name_list, token_name);
            i = i + 1;
        };
        token_name_list
    }

    #[view]
    public fun get_token_symbol_list(pool_id: u64): vector<String> acquires PoolList {
        let token_symbol_list = vector::empty<String>();
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let num_tokens = vector::length(&token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_symbol = record.symbol;
            vector::push_back(&mut token_symbol_list, token_symbol);
            i = i + 1;
        };
        token_symbol_list
    }

    #[view]
    public fun get_pool_balance(pool_id: u64): vector<u256> acquires PoolList {
        let token_balance_list = vector::empty<u256>();
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let num_tokens = vector::length(&token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_balance = record.balance;
            vector::push_back(&mut token_balance_list, token_balance);
            i = i + 1;
        };
        token_balance_list
    }

    #[view]
    public fun get_token_denorm_list(pool_id: u64): vector<u256> acquires PoolList {
        let token_denorm_list = vector::empty<u256>();
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let num_tokens = vector::length(&token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_denorm = record.denorm;
            vector::push_back(&mut token_denorm_list, token_denorm);
            i = i + 1;
        };
        token_denorm_list
    }

    #[view]
    public fun get_token_weight_list(pool_id: u64): vector<u256> acquires PoolList {
        let token_weight_list = vector::empty<u256>();
        let pool_list = borrow_global<PoolList>(@pool_addr);
        let pool = vector::borrow(&pool_list.pool_list, pool_id);
        let token_list = pool.token_list;
        let token_record = pool.token_record;
        let num_tokens = vector::length(&token_list);
        let (total_weight, swap_fee, is_finalized, total_supply, pool_address) = get_pool_info(pool_id);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list, (i as u64));
            let record = simple_map::borrow(&token_record, token_address);
            let token_denorm = record.denorm;
            let weight = token_denorm * BONE / total_weight;
            vector::push_back(&mut token_weight_list, weight);
            i = i + 1;
        };
        token_weight_list
    }

    #[view]
    public fun get_spot_price(pool_id: u64, token_in_name: String, token_in_symbol: String, token_out_name: String, token_out_symbol: String): u256 acquires PoolList {
        let pool_list = borrow_global_mut<PoolList>(@pool_addr);
        let pool = vector::borrow_mut(&mut pool_list.pool_list, pool_id);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);   
        let token_list = &mut pool.token_list;
        let token_record = &mut pool.token_record;
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(token_record, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(token_record, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool.swap_fee,
        );
        spot_price
    }

    // // ========================================= Helper Function ========================================

    // // transfer amount from sender to pool
    fun pull_underlying(sender: &signer, pool_address: address, amount: u256, name: String, symbol: String) {
        let sender_addr = signer::address_of(sender);
        Liquid_Staking_Token::transfer(sender, sender_addr, pool_address, amount, name, symbol);
    }
    
    // // transfer amount from pool to sender
    fun push_underlying(sender: &signer, pool_address: address, amount: u256, name: String, symbol: String) {
        let sender_addr = signer::address_of(sender);
        Liquid_Staking_Token::transfer(sender, pool_address, sender_addr, amount, name, symbol);
    }

    fun mint_and_push_pool_share(sender: &signer, to: address, amount: u256) { 
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::mint(sender, to, amount, lpt_name, lpt_symbol);
    }

    fun pull_pool_share(sender: &signer, pool_address: address, sender_addr: address, amount: u256) {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::transfer(sender, sender_addr, pool_address, amount, lpt_name, lpt_symbol);
    }

    fun burn_pool_share(sender: &signer, pool_address: address, amount: u256) {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::burn(sender, pool_address, amount, lpt_name, lpt_symbol);
    }
    
    // ======================================= Unit Test =========================================

    #[test_only]
    public fun init_module_for_test(sender: &signer) {
        let pool_list = PoolList {
            pool_list: vector::empty(),
        };
        move_to(sender, pool_list);

        let name = string::utf8(b"LP Token");
        let symbol = string::utf8(b"LPT");
        let decimals = 6;
        let icon_uri = string::utf8(b"http://example.com/favicon.ico");
        let project_uri = string::utf8(b"http://example.com");
        Liquid_Staking_Token::create_fa(@lst_addr, name, symbol, decimals, icon_uri, project_uri);
    }
}