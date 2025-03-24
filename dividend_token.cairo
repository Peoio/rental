use starknet::{
        ContractAddress,
        get_caller_address,
        get_block_timestamp
    };
    use core::traits::Into;
    use super::utils::{contract_address_zero, contract_address_try_from_felt252};
    use super::interfaces::IDividendToken;

    #[feature("deprecated_legacy_map")]
    #[starknet::contract]
    mod DividendToken {
        use starknet::{
            ContractAddress, 
            get_caller_address, 
            get_block_timestamp
        };
        use core::traits::Into;
        use super::super::utils::{contract_address_zero, contract_address_try_from_felt252};
        use super::IDividendToken;

        #[storage]
        struct Storage {
            name: felt252,
            symbol: felt252,
            decimals: u8,
            total_supply: u256,
            balances: LegacyMap<ContractAddress, u256>,
            last_withdraw_ts: LegacyMap<ContractAddress, u64>,
            service_owner: ContractAddress,
            commission_pool: u256,
        }

        #[event]
        #[derive(Drop, starknet::Event)]
        enum Event {
            DividendWithdrawn: DividendWithdrawn,
            Transfer: Transfer,
        }

        #[derive(Drop, starknet::Event)]
        struct DividendWithdrawn {
            user: ContractAddress,
            amount: u256,
            commission: u256
        }

        #[derive(Drop, starknet::Event)]
        struct Transfer {
            from: ContractAddress,
            to: ContractAddress,
            amount: u256
        }

        #[constructor]
        fn constructor(
            ref self: ContractState,
            name_: felt252,
            symbol_: felt252,
            decimals_: u8,
            service_owner_: ContractAddress
        ) {
            self.name.write(name_);
            self.symbol.write(symbol_);
            self.decimals.write(decimals_);
            self.total_supply.write(0);
            self.service_owner.write(service_owner_);
            self.commission_pool.write(0);
        }

        #[abi(embed_v0)]
        impl DividendTokenImpl of IDividendToken<ContractState> {
            fn mint(
                ref self: ContractState,
                to: ContractAddress,
                amount: u256
            ) {
                let balance = self.balances.read(to);
                let new_balance = balance + amount;
                self.balances.write(to, new_balance);

                let supply = self.total_supply.read();
                let new_supply = supply + amount;
                self.total_supply.write(new_supply);

                self.emit(Transfer {
                    from: contract_address_zero(),
                    to,
                    amount
                });
            }

            fn withdraw_dividends(
                ref self: ContractState,
                amount: u256
            ) {
                let caller = get_caller_address();
                let last_ts = self.last_withdraw_ts.read(caller);
                let current_ts = get_block_timestamp();
                let month_secs = 2592000_u64;
                assert(current_ts >= last_ts + month_secs, 'Only withdraw every 30 days');

                let balance = self.balances.read(caller);
                assert(balance >= amount, 'Insufficient dividend balance');

                let commission = (amount * 10) / 100;
                let payout = amount - commission;

                self.balances.write(caller, balance - amount);
                
                let commission_pool = self.commission_pool.read();
                self.commission_pool.write(commission_pool + commission);

                let svc_owner = self.service_owner.read();
                let svc_owner_balance = self.balances.read(svc_owner);
                self.balances.write(svc_owner, svc_owner_balance + commission);

                self.last_withdraw_ts.write(caller, current_ts);

                self.emit(DividendWithdrawn { 
                    user: caller,
                    amount: payout,
                    commission
                });

                self.emit(Transfer {
                    from: caller,
                    to: svc_owner,
                    amount: commission
                });

                self.emit(Transfer {
                    from: caller,
                    to: contract_address_zero(),
                    amount: payout
                });
            }

            fn balance_of(self: @ContractState, user: ContractAddress) -> u256 {
                self.balances.read(user)
            }

            fn total_supply(self: @ContractState) -> u256 {
                self.total_supply.read()
            }

            fn decimals(self: @ContractState) -> u8 {
                self.decimals.read()
            }

            fn symbol(self: @ContractState) -> felt252 {
                self.symbol.read()
            }

            fn name(self: @ContractState) -> felt252 {
                self.name.read()
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use starknet::{ContractAddress, get_block_timestamp};
        use core::result::ResultTrait;
        use super::DividendToken;
        use super::super::utils::{contract_address_zero, contract_address_try_from_felt252};

        fn setup_address(value: felt252) -> ContractAddress {
            contract_address_try_from_felt252(value).unwrap()
        }

        #[test]
        fn test_constructor() {
            let mut state = DividendToken::contract_state_for_testing();
            let service_owner = setup_address('service_owner');
            
            DividendToken::constructor(
                ref state, 
                'Dividend Token', 
                'DIV', 
                18, 
                service_owner
            );
            
            assert_eq!(state.name.read(), 'Dividend Token');
            assert_eq!(state.symbol.read(), 'DIV');
            assert_eq!(state.decimals.read(), 18);
            assert_eq!(state.total_supply.read(), 0);
            assert_eq!(state.service_owner.read(), service_owner);
        }

        #[test]
        fn test_mint() {
            let mut state = DividendToken::contract_state_for_testing();
            let service_owner = setup_address('service_owner');
            let recipient = setup_address('recipient');
            
            DividendToken::constructor(
                ref state, 
                'Dividend Token', 
                'DIV', 
                18, 
                service_owner
            );
            
            DividendToken::DividendTokenImpl::mint(ref state, recipient, 100);
            
            let balance = DividendToken::DividendTokenImpl::balance_of(@state, recipient);
            let total_supply = DividendToken::DividendTokenImpl::total_supply(@state);
            
            assert_eq!(balance, 100);
            assert_eq!(total_supply, 100);
        }

        #[test]
        fn test_withdraw_dividends() {
            let mut state = DividendToken::contract_state_for_testing();
            let service_owner = setup_address('service_owner');
            let user = setup_address('user');
            
            starknet::testing::set_caller_address(user);
            
            DividendToken::constructor(
                ref state, 
                'Dividend Token', 
                'DIV', 
                18, 
                service_owner
            );
            
            DividendToken::DividendTokenImpl::mint(ref state, user, 1000);
            
            starknet::testing::set_block_timestamp(2592001);
            
            DividendToken::DividendTokenImpl::withdraw_dividends(ref state, 100);
            
            let user_balance = DividendToken::DividendTokenImpl::balance_of(@state, user);
            let service_owner_balance = DividendToken::DividendTokenImpl::balance_of(@state, service_owner);
            
            assert_eq!(user_balance, 900);
            assert_eq!(service_owner_balance, 10);
            
            let last_withdraw_ts = state.last_withdraw_ts.read(user);
            assert_eq!(last_withdraw_ts, 2592001);
        }

        #[test]
        #[should_panic(expected: 'Only withdraw every 30 days')]
        fn test_withdraw_time_restriction() {
            let mut state = DividendToken::contract_state_for_testing();
            let service_owner = setup_address('service_owner');
            let user = setup_address('user');
            
            starknet::testing::set_caller_address(user);
            
            DividendToken::constructor(
                ref state, 
                'Dividend Token', 
                'DIV', 
                18, 
                service_owner
            );
            
            DividendToken::DividendTokenImpl::mint(ref state, user, 1000);
            
            state.last_withdraw_ts.write(user, 100000);
            
            starknet::testing::set_block_timestamp(100000 + 2592000 - 1);
            
            DividendToken::DividendTokenImpl::withdraw_dividends(ref state, 100);
        }

        #[test]
        #[should_panic(expected: 'Insufficient dividend balance')]
        fn test_withdraw_insufficient_balance() {
            let mut state = DividendToken::contract_state_for_testing();
            let service_owner = setup_address('service_owner');
            let user = setup_address('user');
            
            starknet::testing::set_caller_address(user);
            
            DividendToken::constructor(
                ref state, 
                'Dividend Token', 
                'DIV', 
                18, 
                service_owner
            );
            
            DividendToken::DividendTokenImpl::mint(ref state, user, 50);
            
            starknet::testing::set_block_timestamp(2592001);
            
            DividendToken::DividendTokenImpl::withdraw_dividends(ref state, 100);
        }
    }