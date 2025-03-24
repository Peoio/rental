use starknet::{
    ContractAddress,
    get_caller_address,
};
use core::option::OptionTrait;
use super::utils::{contract_address_zero, contract_address_try_from_felt252};
use super::interfaces::{IERC721, ICarTokenMetadata, CarData, IRentalService, IRentalServiceDispatcher, IRentalServiceDispatcherTrait};

#[feature("deprecated_legacy_map")]
#[starknet::contract]
mod CarToken {
    use super::{IERC721, ICarTokenMetadata, CarData, IRentalServiceDispatcher, IRentalServiceDispatcherTrait};
    use starknet::{ContractAddress, get_caller_address};
    use core::traits::Into;
    use core::option::OptionTrait;
    use super::super::utils::{contract_address_zero, contract_address_try_from_felt252};

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owners: LegacyMap::<u256, ContractAddress>,
        balances: LegacyMap::<ContractAddress, u256>,
        car_details: LegacyMap::<u256, CarData>,
        rental_service: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name_: felt252,
        symbol_: felt252,
        rental_service_: ContractAddress
    ) {
        self.name.write(name_);
        self.symbol.write(symbol_);
        self.rental_service.write(rental_service_);
    }

    #[abi(embed_v0)]
    impl ERC721Impl of IERC721<ContractState> {
        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self.owners.read(token_id);
            assert(owner != contract_address_zero(), 'token does not exist');
            owner
        }

        fn transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256
        ) {
            let owner = self.owner_of(token_id);
            assert(owner == from, 'not token owner');

            let rental_service = IRentalServiceDispatcher { contract_address: self.rental_service.read() };
            let is_rented = rental_service.is_car_rented(token_id);
            assert(!is_rented, 'Car is currently rented');

            self.balances.write(from, self.balances.read(from) - 1);
            self.balances.write(to, self.balances.read(to) + 1);

            self.owners.write(token_id, to);

            self.emit(Transfer { from, to, token_id });
        }
    }

    #[abi(embed_v0)]
    impl CarTokenMetadataImpl of ICarTokenMetadata<ContractState> {
        fn get_car_data(self: @ContractState, token_id: u256) -> CarData {
            assert(self.owners.read(token_id) != contract_address_zero(), 'token does not exist');
            let data = self.car_details.read(token_id);
            data
        }

        fn mint_car(
            ref self: ContractState,
            token_id: u256,
            vin: u256,
            plate_number: u256,
            body_type: u256,
            brand: u256,
            model: u256,
        ) {
            assert(self.owners.read(token_id) == contract_address_zero(), 'token already exists');
            
            let caller = get_caller_address();
            
            self.owners.write(token_id, caller);
            self.balances.write(caller, self.balances.read(caller) + 1);

            self.car_details.write(token_id, CarData {
                vin,
                plate_number,
                body_type,
                brand,
                model
            });

            self.emit(Transfer {
                from: contract_address_zero(),
                to: caller,
                token_id
            });
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn assert_valid_token(self: @ContractState, token_id: u256) {
            assert(self.owners.read(token_id) != contract_address_zero(), 'token does not exist');
        }

        fn assert_owner(self: @ContractState, token_id: u256, owner: ContractAddress) {
            assert(self.owner_of(token_id) == owner, 'not token owner');
        }
    }
}

#[cfg(test)]
mod tests {
    use starknet::{ContractAddress, syscalls::deploy_syscall};
    use core::result::ResultTrait;
    use super::CarToken;
    use super::super::interfaces::{IERC721, ICarTokenMetadata, CarData};
    use super::super::utils::{contract_address_zero, contract_address_try_from_felt252};

    #[starknet::interface]
    trait IMockRental<TContractState> {
        fn is_car_rented(self: @TContractState, token_id: u256) -> bool;
    }

    #[starknet::contract]
    mod mock_rental {
        use starknet::ContractAddress;
        
        #[storage]
        struct Storage {
            rented: bool
        }

        #[constructor]
        fn constructor(ref self: ContractState, is_rented: bool) {
            self.rented.write(is_rented);
        }
        
        #[abi(embed_v0)]
        impl MockImpl of super::IMockRental<ContractState> {
            fn is_car_rented(self: @ContractState, token_id: u256) -> bool {
                self.rented.read()
            }
        }
    }

    fn setup_address(value: felt252) -> ContractAddress {
        contract_address_try_from_felt252(value).unwrap()
    }

    #[test]
    fn test_constructor() {
        let mut state = CarToken::contract_state_for_testing();
        let rental_service = setup_address('rental_service');
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', rental_service);
        
        let name = state.name.read();
        let symbol = state.symbol.read();
        let stored_rental_service = state.rental_service.read();
        
        assert_eq!(name, 'Test Car Token');
        assert_eq!(symbol, 'TCT');
        assert_eq!(stored_rental_service, rental_service);
    }

    #[test]
    fn test_mint_car() {
        let mut state = CarToken::contract_state_for_testing();
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', contract_address_zero());
        
        let caller = setup_address('owner');
        starknet::testing::set_caller_address(caller);
        
        let token_id = 1;
        CarToken::CarTokenMetadataImpl::mint_car(
            ref state,
            token_id,
            123456789,
            987654321,
            1,
            2,
            3,
        );
        
        let owner = CarToken::ERC721Impl::owner_of(@state, token_id);
        assert_eq!(owner, caller);
        
        let balance = state.balances.read(caller);
        assert_eq!(balance, 1);
        
        let car_data = CarToken::CarTokenMetadataImpl::get_car_data(@state, token_id);
        assert_eq!(car_data.vin, 123456789);
        assert_eq!(car_data.plate_number, 987654321);
        assert_eq!(car_data.body_type, 1);
        assert_eq!(car_data.brand, 2);
        assert_eq!(car_data.model, 3);
    }
    
    #[test]
    fn test_transfer_from() {
        let mut state = CarToken::contract_state_for_testing();
        let car_token_addr = setup_address(2222);
        starknet::testing::set_contract_address(car_token_addr);
        let rental_service_addr = setup_address(1111);
        let mut mock = mock_rental::contract_state_for_testing();
        starknet::testing::set_contract_address(rental_service_addr);
        mock_rental::constructor(ref mock, false);
        starknet::testing::set_contract_address(car_token_addr);
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', rental_service_addr);
        let owner = setup_address(3333);
        let recipient = setup_address(4444);
        
        starknet::testing::set_caller_address(owner);
        let token_id = 1;
        CarToken::CarTokenMetadataImpl::mint_car(
            ref state,
            token_id,
            123456789,
            987654321,
            1,
            2,
            3,
        );
        starknet::testing::set_contract_address(rental_service_addr);
        CarToken::ERC721Impl::transfer_from(
            ref state,
            owner,
            recipient,
            token_id
        );
        let new_owner = CarToken::ERC721Impl::owner_of(@state, token_id);
        assert_eq!(new_owner, recipient);
        
        let owner_balance = state.balances.read(owner);
        let recipient_balance = state.balances.read(recipient);
        assert_eq!(owner_balance, 0);
        assert_eq!(recipient_balance, 1);
    }
    
    #[test]
    #[should_panic(expected: 'token does not exist')]
    fn test_assert_valid_token_fail() {
        let mut state = CarToken::contract_state_for_testing();
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', contract_address_zero());
        
        CarToken::InternalImpl::assert_valid_token(@state, 999);
    }
    
    #[test]
    #[should_panic(expected: 'not token owner')]
    fn test_assert_owner_fail() {
        let mut state = CarToken::contract_state_for_testing();
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', contract_address_zero());
        
        let owner = setup_address('owner');
        let not_owner = setup_address('not_owner');
        starknet::testing::set_caller_address(owner);
        
        let token_id = 1;
        CarToken::CarTokenMetadataImpl::mint_car(
            ref state,
            token_id,
            123456789,
            987654321,
            1,
            2,
            3,
        );
        
        CarToken::InternalImpl::assert_owner(@state, token_id, not_owner);
    }

    #[test]
    #[should_panic(expected: 'Car is currently rented')]
    fn test_transfer_rented_car() {
        let mut state = CarToken::contract_state_for_testing();
        let car_token_addr = setup_address(2222);
        starknet::testing::set_contract_address(car_token_addr);
        let rental_service_addr = setup_address(1111);
        let mut mock = mock_rental::contract_state_for_testing();
        starknet::testing::set_contract_address(rental_service_addr);
        mock_rental::constructor(ref mock, true);
        starknet::testing::set_contract_address(car_token_addr);
        CarToken::constructor(ref state, 'Test Car Token', 'TCT', rental_service_addr);
        let owner = setup_address(3333);
        let recipient = setup_address(4444);
        
        starknet::testing::set_caller_address(owner);
        let token_id = 1;
        CarToken::CarTokenMetadataImpl::mint_car(
            ref state,
            token_id,
            123456789,
            987654321,
            1,
            2,
            3,
        );
        starknet::testing::set_contract_address(rental_service_addr);
        CarToken::ERC721Impl::transfer_from(
            ref state,
            owner,
            recipient,
            token_id
        );
    }
}