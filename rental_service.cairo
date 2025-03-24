use starknet::{
    ContractAddress,
    get_caller_address,
    get_contract_address,
    get_block_timestamp,
    SyscallResultTrait,
    class_hash::ClassHash
};
use core::traits::Into;
use core::option::OptionTrait;
use core::array::ArrayTrait;
use core::result::ResultTrait;
use super::interfaces::{IRentalService, Listing, Rental, IERC721, IDividendToken};

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
}

#[feature("deprecated_legacy_map")]
#[starknet::contract]
mod RentalService {
    use starknet::{
        ContractAddress,
        get_caller_address,
        get_contract_address,
        get_block_timestamp,
    };
    use core::traits::Into;
    use core::option::OptionTrait;
    use core::result::ResultTrait;
    use super::super::interfaces::{
        IRentalService,
        Listing,
        Rental,
        IERC721Dispatcher,
        IERC721DispatcherTrait,
        IDividendTokenDispatcher,
        IDividendTokenDispatcherTrait
    };
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};

    #[storage]
    struct Storage {
        car_token: ContractAddress,
        dividend_token: ContractAddress,
        payment_token: ContractAddress,
        service_owner: ContractAddress,
        guard: bool,
        commission_rate: u8,
        listings: LegacyMap::<u256, Listing>,
        active_listings: LegacyMap::<u256, bool>,
        rentals: LegacyMap::<u256, Rental>,
        active_rentals: LegacyMap::<u256, bool>,
        deposit_forfeit_percentages: LegacyMap::<u256, u8>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CarListed: CarListed,
        CarUnlisted: CarUnlisted,
        CarRented: CarRented,
        CarReturned: CarReturned,
        DepositForfeited: DepositForfeited
    }

    #[derive(Drop, starknet::Event)]
    struct CarListed {
        token_id: u256,
        owner: ContractAddress,
        daily_price: u256,
        deposit: u256
    }

    #[derive(Drop, starknet::Event)]
    struct CarUnlisted {
        token_id: u256,
        owner: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct CarRented {
        token_id: u256,
        renter: ContractAddress,
        duration: u64,
        total_paid: u256
    }

    #[derive(Drop, starknet::Event)]
    struct CarReturned {
        token_id: u256,
        renter: ContractAddress,
        deposit_returned: u256
    }
    
    #[derive(Drop, starknet::Event)]
    struct DepositForfeited {
        token_id: u256,
        renter: ContractAddress,
        amount: u256,
        reason: felt252
    }

    mod Errors {
        const REENTRANCY: felt252 = 'Reentrant call';
        const NOT_LISTED: felt252 = 'Car not listed';
        const ALREADY_LISTED: felt252 = 'Car already listed';
        const ALREADY_RENTED: felt252 = 'Car already rented';
        const NO_RENTAL: felt252 = 'No active rental';
        const NOT_RENTER: felt252 = 'Not the renter';
        const RENTAL_NOT_OVER: felt252 = 'Rental period not over';
        const OWN_CAR: felt252 = 'Cannot rent own car';
        const NOT_LISTING_OWNER: felt252 = 'Not listing owner';
        const NOT_NFT_OWNER: felt252 = 'Not NFT owner';
        const PAYMENT_FAILED: felt252 = 'Payment failed';
        const REFUND_FAILED: felt252 = 'Refund failed';
        const INVALID_DURATION: felt252 = 'Invalid duration';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        car_token_: ContractAddress,
        dividend_token_: ContractAddress,
        payment_token_: ContractAddress,
        service_owner_: ContractAddress
    ) {
        self.car_token.write(car_token_);
        self.dividend_token.write(dividend_token_);
        self.payment_token.write(payment_token_);
        self.service_owner.write(service_owner_);
        self.commission_rate.write(10);
        self.guard.write(false);
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn assert_not_entered(ref self: ContractState) {
            assert(!self.guard.read(), 'Reentrant call');
            self.guard.write(true);
        }

        fn exit(ref self: ContractState) {
            self.guard.write(false);
        }

        fn assert_nft_owner(self: @ContractState, token_id: u256, expected_owner: ContractAddress) {
            let car_token = IERC721Dispatcher { contract_address: self.car_token.read() };
            let actual_owner = car_token.owner_of(token_id);
            assert(actual_owner == expected_owner, 'Not NFT owner');
        }

        fn transfer_payment(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256) -> bool {
            let payment_token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            payment_token.transfer_from(from, to, amount)
        }

        fn transfer_to(ref self: ContractState, to: ContractAddress, amount: u256) -> bool {
            let payment_token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            payment_token.transfer(to, amount)
        }

        fn mint_dividend_tokens(ref self: ContractState, to: ContractAddress, amount: u256) {
            let dividend_token = IDividendTokenDispatcher { contract_address: self.dividend_token.read() };
            dividend_token.mint(to, amount);
        }

        fn verify_nft_owner(self: @ContractState, token_id: u256, expected_owner: ContractAddress) {
            let car_token = IERC721Dispatcher { contract_address: self.car_token.read() };
            let actual_owner = car_token.owner_of(token_id);
            assert(actual_owner == expected_owner, Errors::NOT_NFT_OWNER);
        }
    }

    #[abi(embed_v0)]
    impl RentalServiceImpl of IRentalService<ContractState> {
        fn list_car(
            ref self: ContractState,
            token_id: u256,
            daily_price: u256,
            deposit: u256
        ) {
            InternalImpl::assert_not_entered(ref self);

            let caller = get_caller_address();
            assert(!self.active_listings.read(token_id), Errors::ALREADY_LISTED);

            InternalImpl::verify_nft_owner(@self, token_id, caller);

            let listing = Listing {
                owner: caller,
                daily_price,
                deposit,
                is_listed: true
            };
            self.listings.write(token_id, listing);
            self.active_listings.write(token_id, true);

            self.emit(CarListed { 
                token_id, 
                owner: caller, 
                daily_price, 
                deposit 
            });
            InternalImpl::exit(ref self);
        }

        fn unlist_car(
            ref self: ContractState,
            token_id: u256
        ) {
            InternalImpl::assert_not_entered(ref self);
            assert(self.active_listings.read(token_id), Errors::NOT_LISTED);

            let listing = self.listings.read(token_id);
            let caller = get_caller_address();
            assert(listing.owner == caller, Errors::NOT_LISTING_OWNER);
            assert(!self.active_rentals.read(token_id), Errors::ALREADY_RENTED);

            self.active_listings.write(token_id, false);

            let mut updated_listing = listing;
            updated_listing.is_listed = false;
            self.listings.write(token_id, updated_listing);

            self.emit(CarUnlisted { 
                token_id, 
                owner: caller 
            });

            InternalImpl::exit(ref self);
        }

        fn rent_car(
            ref self: ContractState,
            token_id: u256,
            duration_days: u64
        ) {
            InternalImpl::assert_not_entered(ref self);

            assert(self.active_listings.read(token_id), Errors::NOT_LISTED);
            assert(!self.active_rentals.read(token_id), Errors::ALREADY_RENTED);
            assert(duration_days > 0, 'Duration must be positive');
            
            let listing = self.listings.read(token_id);
            let caller = get_caller_address();
            assert(listing.owner != caller, Errors::OWN_CAR);

            let rental_cost = listing.daily_price * duration_days.into();
            let total_required = rental_cost + listing.deposit;
            
            let success = InternalImpl::transfer_payment(
                ref self,
                caller,
                get_contract_address(),
                total_required
            );
            assert(success, Errors::PAYMENT_FAILED);

            let commission = (rental_cost * 10) / 100;
            let owner_portion = rental_cost - commission;

            InternalImpl::transfer_to(ref self, listing.owner, owner_portion);
            InternalImpl::transfer_to(ref self, self.service_owner.read(), commission);

            InternalImpl::mint_dividend_tokens(ref self, listing.owner, owner_portion);

            let start_time = get_block_timestamp();
            let rental = Rental {
                renter: caller,
                start_time,
                end_time: start_time + (duration_days * 86400),
                paid_amount: total_required
            };
            
            self.rentals.write(token_id, rental);
            self.active_rentals.write(token_id, true);

            self.emit(CarRented {
                token_id,
                renter: caller,
                duration: duration_days,
                total_paid: total_required
            });
            
            InternalImpl::exit(ref self);
        }

        fn return_car(
            ref self: ContractState,
            token_id: u256
        ) {
            InternalImpl::assert_not_entered(ref self);

            assert(self.active_rentals.read(token_id), Errors::NO_RENTAL);
            
            let rental = self.rentals.read(token_id);
            let caller = get_caller_address();
            assert(rental.renter == caller, Errors::NOT_RENTER);

            let current_time = get_block_timestamp();
            let listing = self.listings.read(token_id);
            
            let mut refund_amount: u256 = 0;
            if current_time < rental.end_time {
                let used_duration = current_time - rental.start_time;
                let total_duration = rental.end_time - rental.start_time;
                let unused_duration = total_duration - used_duration;
                let days_unused = unused_duration / 86400;
                
                if days_unused > 0 {
                    let unused_amount = listing.daily_price * days_unused.into();
                    let penalty = (unused_amount * 30) / 100;
                    refund_amount = unused_amount - penalty;
                    
                    let success = InternalImpl::transfer_to(ref self, listing.owner, penalty);
                    assert(success, Errors::PAYMENT_FAILED);
                    
                    InternalImpl::mint_dividend_tokens(ref self, listing.owner, penalty);
                }
            }

            let forfeit_percentage = self.deposit_forfeit_percentages.read(token_id);
            let deposit = listing.deposit;
            
            if forfeit_percentage > 0 {
                let forfeit_amount = (deposit * forfeit_percentage.into()) / 100;
                let return_amount = deposit - forfeit_amount;
                
                let success_renter = InternalImpl::transfer_to(ref self, caller, return_amount + refund_amount);
                assert(success_renter, Errors::REFUND_FAILED);
                
                let success_owner = InternalImpl::transfer_to(ref self, listing.owner, forfeit_amount);
                assert(success_owner, Errors::PAYMENT_FAILED);
                
                InternalImpl::mint_dividend_tokens(ref self, listing.owner, forfeit_amount);
                
                self.emit(DepositForfeited {
                    token_id,
                    renter: caller,
                    amount: forfeit_amount,
                    reason: 'Damage or late return'
                });
                
                self.emit(CarReturned {
                    token_id,
                    renter: caller,
                    deposit_returned: return_amount
                });
            } else {
                let success = InternalImpl::transfer_to(ref self, caller, deposit + refund_amount);
                assert(success, Errors::REFUND_FAILED);
                
                self.emit(CarReturned {
                    token_id,
                    renter: caller,
                    deposit_returned: deposit
                });
            }
            
            self.deposit_forfeit_percentages.write(token_id, 0);
            self.active_rentals.write(token_id, false);
            
            InternalImpl::exit(ref self);
        }

        fn get_listing(self: @ContractState, token_id: u256) -> Listing {
            assert(self.active_listings.read(token_id), Errors::NOT_LISTED);
            self.listings.read(token_id)
        }

        fn get_rental(self: @ContractState, token_id: u256) -> Rental {
            assert(self.active_rentals.read(token_id), Errors::NO_RENTAL);
            self.rentals.read(token_id)
        }
        
        fn is_car_rented(self: @ContractState, token_id: u256) -> bool {
            self.active_rentals.read(token_id)
        }

        fn set_deposit_forfeit(
            ref self: ContractState,
            token_id: u256,
            forfeit_percentage: u8
        ) {
            InternalImpl::assert_not_entered(ref self);
            
            let listing = self.listings.read(token_id);
            let caller = get_caller_address();
            assert(
                listing.owner == caller || self.service_owner.read() == caller,
                'Not authorized to set forfeit'
            );
            
            assert(self.active_rentals.read(token_id), Errors::NO_RENTAL);
            
            assert(forfeit_percentage <= 100, 'Invalid forfeit percentage');
            
            self.deposit_forfeit_percentages.write(token_id, forfeit_percentage);
            
            InternalImpl::exit(ref self);
        }
    }
}

#[cfg(test)]
mod tests {
    use core::result::ResultTrait;
    use core::option::OptionTrait;
    use core::traits::Into;
    use starknet::{ContractAddress, get_caller_address};
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
    use super::RentalService;
    use super::super::interfaces::{Listing, Rental};
    use super::super::utils::{contract_address_zero, contract_address_try_from_felt252};

    fn setup_address(value: felt252) -> ContractAddress {
        contract_address_try_from_felt252(value).unwrap()
    }

    #[test]
    fn test_constructor() {
        let mut state = RentalService::contract_state_for_testing();
        
        let car_token = setup_address(1111);
        let dividend_token = setup_address(2222);
        let payment_token = setup_address(3333);
        let service_owner = setup_address(4444);
        
        RentalService::constructor(
            ref state,
            car_token,
            dividend_token,
            payment_token,
            service_owner
        );
        
        assert(state.car_token.read() == car_token, 'Wrong car token');
        assert(state.dividend_token.read() == dividend_token, 'Wrong dividend token');
        assert(state.payment_token.read() == payment_token, 'Wrong payment token');
        assert(state.service_owner.read() == service_owner, 'Wrong service owner');
        assert(!state.guard.read(), 'Guard should be false');
    }

    #[test]
    fn test_reentrancy_guard() {
        let mut state = RentalService::contract_state_for_testing();
        
        assert(!state.guard.read(), 'Guard should be false');
        
        RentalService::InternalImpl::assert_not_entered(ref state);
        
        assert(state.guard.read(), 'Guard should be true');
        
        RentalService::InternalImpl::exit(ref state);
        
        assert(!state.guard.read(), 'Guard should be false again');
    }

    #[test]
    #[should_panic(expected: ('Reentrant call',))]
    fn test_reentrancy_protection() {
        let mut state = RentalService::contract_state_for_testing();
        state.guard.write(true);
        RentalService::InternalImpl::assert_not_entered(ref state);
    }

    #[test]
    fn test_list_car() {
        let mut state = RentalService::contract_state_for_testing();
        let car_owner = setup_address(1111);
        
        RentalService::constructor(
            ref state,
            setup_address(2222),
            setup_address(3333),
            setup_address(4444),
            setup_address(5555)
        );
        
        let token_id: u256 = 1;
        let mut calldata: Array<felt252> = array![];
        calldata.append(token_id.low.into());
        calldata.append(token_id.high.into());
        
        starknet::testing::set_contract_address(setup_address(2222));
        starknet::testing::set_caller_address(car_owner);
        
        let daily_price: u256 = 10;
        let deposit: u256 = 100;
        
        RentalService::RentalServiceImpl::list_car(
            ref state, 
            token_id,
            daily_price,
            deposit
        );
        
        let listing = RentalService::RentalServiceImpl::get_listing(@state, token_id);
        assert_eq!(listing.owner, car_owner);
        assert_eq!(listing.daily_price, daily_price);
        assert_eq!(listing.deposit, deposit);
        assert_eq!(listing.is_listed, true);
        assert_eq!(state.active_listings.read(token_id), true);
    }

    #[test]
    #[should_panic(expected: ('Car already listed',))]
    fn test_list_car_already_listed() {
        let mut state = RentalService::contract_state_for_testing();
        let car_owner = setup_address(1111);
        
        RentalService::constructor(
            ref state,
            setup_address(2222),
            setup_address(3333),
            setup_address(4444),
            setup_address(5555)
        );
        
        let token_id: u256 = 1;
        state.active_listings.write(token_id, true);
        
        set_caller_address(car_owner);
        RentalService::RentalServiceImpl::list_car(
            ref state,
            token_id,
            10,
            100
        );
    }

    #[test]
    fn test_unlist_car() {
        let mut state = RentalService::contract_state_for_testing();
        let car_token = setup_address(1111);
        let dividend_token = setup_address(2222);
        let payment_token = setup_address(3333);
        let service_owner = setup_address(4444);
        let car_owner = setup_address(5555);
        
        RentalService::constructor(
            ref state,
            car_token,
            dividend_token,
            payment_token,
            service_owner
        );

        let token_id = 1;
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);

        starknet::testing::set_caller_address(car_owner);

        RentalService::RentalServiceImpl::unlist_car(ref state, token_id);

        assert_eq!(state.active_listings.read(token_id), false);

        let updated_listing = state.listings.read(token_id);
        assert_eq!(updated_listing.is_listed, false);
    }

    #[test]
    #[should_panic(expected: ('Car not listed',))]
    fn test_unlist_car_not_listed() {
        let mut state = RentalService::contract_state_for_testing();
        let car_token = setup_address(1111);
        let dividend_token = setup_address(2222);
        let payment_token = setup_address(3333);
        let service_owner = setup_address(4444);
        let car_owner = setup_address(5555);

        RentalService::constructor(
            ref state,
            car_token,
            dividend_token,
            payment_token,
            service_owner
        );

        starknet::testing::set_caller_address(car_owner);
        RentalService::RentalServiceImpl::unlist_car(ref state, 1);
    }

    #[test]
    #[should_panic(expected: ('Not listing owner',))]
    fn test_unlist_car_wrong_owner() {
        let mut state = RentalService::contract_state_for_testing();
        let car_token = setup_address(1111);
        let dividend_token = setup_address(2222);
        let payment_token = setup_address(3333);
        let service_owner = setup_address(4444);
        let car_owner = setup_address(5555);
        let attacker = setup_address(6666);

        RentalService::constructor(
            ref state,
            car_token,
            dividend_token,
            payment_token,
            service_owner
        );

        let token_id = 1;
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);

        starknet::testing::set_caller_address(attacker);
        RentalService::RentalServiceImpl::unlist_car(ref state, token_id);
    }

    #[test]
    fn test_rent_car() {
        let mut state = RentalService::contract_state_for_testing();
        
        let car_owner = setup_address(1111);
        let renter = setup_address(2222);
        let payment_token = setup_address(3333);
        
        RentalService::constructor(
            ref state,
            setup_address(4444),
            setup_address(5555),
            payment_token,
            setup_address(6666)
        );
        
        starknet::testing::set_caller_address(car_owner);
        let token_id: u256 = 1;
        let daily_price: u256 = 10;
        let deposit: u256 = 100;
        
        RentalService::RentalServiceImpl::list_car(
            ref state,
            token_id,
            daily_price,
            deposit
        );
        
        starknet::testing::set_caller_address(renter);
        starknet::testing::set_contract_address(payment_token);
        
        let current_time: u64 = 1000000;
        starknet::testing::set_block_timestamp(current_time);
        
        let duration_days: u64 = 5;
        RentalService::RentalServiceImpl::rent_car(ref state, token_id, duration_days);
        
        let rental = RentalService::RentalServiceImpl::get_rental(@state, token_id);
        assert(rental.renter == renter, 'Wrong renter');
        assert(rental.start_time == current_time, 'Wrong start time');
        assert(rental.end_time == current_time + (duration_days * 86400), 'Wrong end time');
        assert(rental.paid_amount == (daily_price * duration_days.into()) + deposit, 'Wrong paid amount');
        assert(state.active_rentals.read(token_id), 'Rental not active');
    }

    #[test]
    #[should_panic(expected: ('Car not listed',))]
    fn test_rent_car_not_listed() {
        let mut state = RentalService::contract_state_for_testing();
        let renter = setup_address(1111);
        
        RentalService::constructor(
            ref state,
            setup_address(2222),
            setup_address(3333),
            setup_address(4444),
            setup_address(5555)
        );
        
        starknet::testing::set_caller_address(renter);
        RentalService::RentalServiceImpl::rent_car(ref state, 1, 5);
    }

    #[test]
    #[should_panic(expected: ('Car already rented',))]
    fn test_rent_car_already_rented() {
        let mut state = RentalService::contract_state_for_testing();
        let car_owner = setup_address(1111);
        let renter = setup_address(2222);
        
        RentalService::constructor(
            ref state,
            setup_address(3333),
            setup_address(4444),
            setup_address(5555),
            setup_address(6666)
        );
        
        let token_id: u256 = 1;
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);
        state.active_rentals.write(token_id, true);
        
        starknet::testing::set_caller_address(renter);
        RentalService::RentalServiceImpl::rent_car(ref state, token_id, 5);
    }

    #[test]
    #[should_panic(expected: ('Cannot rent own car',))]
    fn test_rent_own_car() {
        let mut state = RentalService::contract_state_for_testing();
        let car_owner = setup_address(1111);
        
        RentalService::constructor(
            ref state,
            setup_address(2222),
            setup_address(3333),
            setup_address(4444),
            setup_address(5555)
        );
        
        let token_id: u256 = 1;
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);
        
        starknet::testing::set_caller_address(car_owner);
        RentalService::RentalServiceImpl::rent_car(ref state, token_id, 5);
    }

    fn setup_test_rental(
        ref state: RentalService::ContractState,
        token_id: u256,
        car_owner: ContractAddress,
        renter: ContractAddress,
        start_time: u64,
        duration_days: u64,
        daily_price: u256,
        deposit: u256
    ) {
        let listing = Listing {
            owner: car_owner,
            daily_price,
            deposit,
            is_listed: true
        };
        
        let rental = Rental {
            renter,
            start_time,
            end_time: start_time + (duration_days * 86400),
            paid_amount: (daily_price * duration_days.into()) + deposit
        };
        
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);
        state.rentals.write(token_id, rental);
        state.active_rentals.write(token_id, true);
    }

    #[test]
    fn test_return_car() {
        let mut state = RentalService::contract_state_for_testing();
        let car_owner = setup_address(1111);
        let renter = setup_address(2222);
        let payment_token = setup_address(3333);
        
        RentalService::constructor(
            ref state,
            setup_address(4444),
            setup_address(5555),
            payment_token,
            setup_address(6666)
        );
        
        let token_id: u256 = 1;
        let start_time: u64 = 1000000;
        let duration_days: u64 = 5;
        let end_time = start_time + (duration_days * 86400);
        
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);
        
        let rental = Rental {
            renter,
            start_time,
            end_time,
            paid_amount: 150
        };
        state.rentals.write(token_id, rental);
        state.active_rentals.write(token_id, true);
        
        starknet::testing::set_contract_address(payment_token);
        starknet::testing::set_caller_address(renter);
        starknet::testing::set_block_timestamp(end_time + 1);
        
        RentalService::RentalServiceImpl::return_car(ref state, token_id);
        
        assert(!state.active_rentals.read(token_id), 'Rental still active');
    }

    #[test]
    #[should_panic(expected: ('No active rental',))]
    fn test_return_car_no_rental() {
        let mut state = RentalService::contract_state_for_testing();
        
        RentalService::constructor(
            ref state,
            setup_address(1111),
            setup_address(2222),
            setup_address(3333),
            setup_address(4444)
        );
        
        RentalService::RentalServiceImpl::return_car(ref state, 1);
    }

    #[test]
    #[should_panic(expected: ('Not the renter',))]
    fn test_return_car_not_renter() {
        let mut state = RentalService::contract_state_for_testing();
        let renter = setup_address(1111);
        let not_renter = setup_address(2222);
        
        RentalService::constructor(
            ref state,
            setup_address(3333),
            setup_address(4444),
            setup_address(5555),
            setup_address(6666)
        );
        
        let token_id: u256 = 1;
        let rental = Rental {
            renter,
            start_time: 1000000,
            end_time: 1500000,
            paid_amount: 150
        };
        
        state.rentals.write(token_id, rental);
        state.active_rentals.write(token_id, true);
        
        starknet::testing::set_caller_address(not_renter);
        RentalService::RentalServiceImpl::return_car(ref state, token_id);
    }

    #[test]
    #[should_panic(expected: ('Rental period not over',))]
    fn test_return_car_period_not_over() {
        let mut state = RentalService::contract_state_for_testing();
        let renter = setup_address(1111);
        let car_owner = setup_address(2222);
        let payment_token = setup_address(3333);
        
        RentalService::constructor(
            ref state,
            setup_address(4444),
            setup_address(5555),
            payment_token,
            setup_address(6666)
        );
        
        let token_id: u256 = 1;
        let start_time: u64 = 1000000;
        let duration_days: u64 = 5;
        let end_time = start_time + (duration_days * 86400);
        
        let listing = Listing {
            owner: car_owner,
            daily_price: 10,
            deposit: 100,
            is_listed: true
        };
        state.listings.write(token_id, listing);
        state.active_listings.write(token_id, true);
        
        let rental = Rental {
            renter,
            start_time,
            end_time,
            paid_amount: 150
        };
        state.rentals.write(token_id, rental);
        state.active_rentals.write(token_id, true);
        
        starknet::testing::set_contract_address(payment_token);
        starknet::testing::set_caller_address(renter);
        starknet::testing::set_block_timestamp(start_time + 86400);
        
        RentalService::RentalServiceImpl::return_car(ref state, token_id);
    }

    fn mock_car_token_owner(token_id: u256, owner: ContractAddress) {
        let mut calldata: Array<felt252> = array![];
        calldata.append(token_id.try_into().unwrap());
        let mut retdata: Array<felt252> = array![];
        retdata.append(owner.into());
        set_caller_address(owner);
    }
}